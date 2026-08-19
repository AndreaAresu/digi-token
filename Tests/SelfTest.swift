import AppKit
import Foundation

/// Headless checks over the real logs on this machine plus synthetic fixtures.
///
/// The app is a GUI, so the parts worth testing are the ones that never touch a
/// view: log parsing, deduplication, block bucketing, and the digivolution
/// graph. `scripts/test.sh` compiles this against Core and Digi only.
@main
enum SelfTest {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if condition {
            print("  ok   \(message)")
        } else {
            failures += 1
            print("  FAIL \(message)")
        }
    }

    static func section(_ title: String) {
        print("\n\u{001B}[1m\(title)\u{001B}[0m")
    }

    static func main() async {
        section("DigiDex index")
        let dex = DigiDex.shared
        expect(dex.all.count > 1_000, "roster loaded (\(dex.all.count) digimon)")
        for stage in DigiStage.allCases {
            let count = dex.entries(stage: stage).count
            expect(count > 20, "\(stage.dubName)/\(stage.rawName): \(count) forms")
        }
        let withEdges = dex.all.filter { !$0.next.isEmpty }.count
        expect(withEdges > 500, "evolution graph populated (\(withEdges) with outgoing edges)")
        let xCount = dex.all.filter(\.x).count
        expect(xCount > 50, "X-Antibody variants present (\(xCount))")

        section("Token parsing — synthetic")
        testClaudeParsing()
        testCodexParsing()

        section("Block bucketing")
        testBlocks()

        section("Streaks")
        testStreaks()

        section("Digivolution")
        testDigivolution()

        section("Care profile")
        testCare()

        section("Cache retention")
        testRetention()

        section("Sprite processing")
        testSpriteProcessing()

        section("Real logs on this machine")
        await testRealLogs()

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Parsing

    static func testClaudeParsing() {
        let line = """
        {"type":"assistant","uuid":"u1","timestamp":"2026-08-19T10:00:00.000Z",\
        "sessionId":"s1","requestId":"req_1","cwd":"/tmp/proj",\
        "message":{"id":"msg_1","model":"claude-fable-5","usage":{"input_tokens":100,\
        "output_tokens":50,"cache_creation_input_tokens":20,"cache_read_input_tokens":900}}}
        """
        let event = ClaudeCodeProvider.parse(line: Data(line.utf8), fallbackSession: "x")
        expect(event != nil, "claude: assistant record parses")
        expect(event?.counts.input == 100, "claude: input tokens")
        expect(event?.counts.cacheRead == 900, "claude: cache read tokens")
        expect(event?.counts.billable == 170, "claude: billable excludes cache reads")
        expect(event?.dedupKey == "req_1:msg_1", "claude: dedup key pairs request and message")
        expect(event?.project == "proj", "claude: project from cwd")

        let userLine = #"{"type":"user","timestamp":"2026-08-19T10:00:00.000Z"}"#
        expect(
            ClaudeCodeProvider.parse(line: Data(userLine.utf8), fallbackSession: "x") == nil,
            "claude: non-assistant records ignored"
        )

        // A record with no usage must not count as a zero-token event, or the
        // session count inflates on every transcript.
        let noUsage = #"{"type":"assistant","timestamp":"2026-08-19T10:00:00.000Z","message":{"id":"m"}}"#
        expect(
            ClaudeCodeProvider.parse(line: Data(noUsage.utf8), fallbackSession: "x") == nil,
            "claude: records without usage ignored"
        )
    }

    static func testCodexParsing() {
        let line = """
        {"timestamp":"2026-08-19T10:00:00.000Z","type":"event_msg","payload":{"type":"token_count",\
        "info":{"last_token_usage":{"input_tokens":13607,"cached_input_tokens":9600,\
        "cache_write_input_tokens":0,"output_tokens":256,"total_tokens":13863}}}}
        """
        let event = CodexProvider.parse(line: Data(line.utf8), session: "s", sequence: 3, path: "/p")
        expect(event != nil, "codex: token_count record parses")
        // Codex folds cached tokens into input_tokens; we split them back out so
        // "input" means the same thing across providers.
        expect(event?.counts.input == 4007, "codex: cached tokens removed from input")
        expect(event?.counts.cacheRead == 9600, "codex: cached tokens kept separately")
        expect(event?.counts.billable == 4263, "codex: billable excludes cache reads")
        expect(event?.dedupKey == "/p#3", "codex: dedup key is positional")
    }

    // MARK: - Aggregation

    static func makeEvent(_ minutesFromNow: Int, tokens: Int, key: String) -> UsageEvent {
        UsageEvent(
            timestamp: Date().addingTimeInterval(Double(minutesFromNow) * 60),
            model: "claude-sonnet-5",
            counts: TokenCounts(input: tokens, output: 0, cacheCreation: 0, cacheRead: 0),
            dedupKey: key, sessionID: "s", project: nil
        )
    }

    static func testBlocks() {
        let events = [
            makeEvent(-600, tokens: 10, key: "a"),
            makeEvent(-580, tokens: 10, key: "b"),
            makeEvent(-30, tokens: 10, key: "c"),
        ]
        let blocks = UsageAggregator.blocks(from: events)
        expect(blocks.count == 2, "a 9-hour gap opens a second window (got \(blocks.count))")
        expect(blocks.first?.counts.input == 20, "adjacent events share a window")
        expect(blocks.last?.isActive == true, "the newest window is still active")

        let duplicates = [
            makeEvent(-10, tokens: 100, key: "same"),
            makeEvent(-9, tokens: 100, key: "same"),
        ]
        let usage = UsageAggregator.summarize(provider: .claudeCode, events: duplicates)
        expect(usage.allTime.input == 100, "a forked transcript counts a turn once")
    }

    static func testStreaks() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let days = (0..<5).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        expect(UsageAggregator.streak(activeDays: days) == 5, "five consecutive days")

        let gapped = [days[0], days[1], days[3]]
        expect(UsageAggregator.streak(activeDays: gapped) == 2, "a gap ends the streak")

        // A streak must survive midnight before the new day has been worked.
        let yesterdayOnly = [days[1], days[2]]
        expect(
            UsageAggregator.streak(activeDays: yesterdayOnly) == 2,
            "a streak through yesterday still counts today"
        )
        expect(UsageAggregator.streak(activeDays: []) == 0, "no activity means no streak")
    }

    // MARK: - Digimon

    static func testDigivolution() {
        let profile = CareProfile()
        guard let hatched = Digivolution.hatch(seed: 42, profile: profile) else {
            expect(false, "hatching produces a Baby I")
            return
        }
        expect(hatched.entry.stageLabel == .babyI, "hatch lands on Baby I (\(hatched.entry.name))")

        // Same seed, same result — otherwise relaunching the app rerolls.
        let again = Digivolution.hatch(seed: 42, profile: profile)
        expect(again?.entry.id == hatched.entry.id, "hatching is deterministic for a seed")

        // Every rung must resolve for every starting form, including the many
        // whose canon evolution data dead-ends.
        var walked = 0
        var current = hatched.entry
        var stage = DigiStage.babyI
        while let next = stage.next {
            guard let result = Digivolution.next(
                from: current, to: next, seed: 42, profile: profile, wantsXAntibody: false
            ) else { break }
            expect(
                result.entry.stageLabel == next,
                "\(current.name) → \(result.entry.name) reaches \(next.dubName)"
            )
            current = result.entry
            stage = next
            walked += 1
        }
        expect(walked == 5, "a full ladder walks Baby I to Ultimate (\(walked) steps)")

        // The fallback chain must never leave a form stranded, whatever it is.
        var stranded: [String] = []
        for entry in DigiDex.shared.entries(stage: .child).prefix(120) {
            if Digivolution.next(
                from: entry, to: .adult, seed: 7, profile: profile, wantsXAntibody: false
            ) == nil {
                stranded.append(entry.name)
            }
        }
        expect(stranded.isEmpty, "no Child form dead-ends at Adult (\(stranded.prefix(3)))")

        // Alignment has to actually change outcomes, or the care system is décor.
        var vaccine = CareProfile(); vaccine.attribute = .vaccine
        var virus = CareProfile(); virus.attribute = .virus
        var differing = 0
        for entry in DigiDex.shared.entries(stage: .child).prefix(60) {
            let a = Digivolution.next(from: entry, to: .adult, seed: 11, profile: vaccine, wantsXAntibody: false)
            let b = Digivolution.next(from: entry, to: .adult, seed: 11, profile: virus, wantsXAntibody: false)
            if a?.entry.id != b?.entry.id { differing += 1 }
        }
        expect(differing > 10, "alignment steers the branch (\(differing)/60 differ)")

        // Jogress must resolve for arbitrary pairs, including two Megas, whose
        // combined stage has no rung above it.
        var fusions = 0
        let megas = Array(DigiDex.shared.entries(stage: .ultimate).prefix(20))
        for (index, left) in megas.enumerated() where index + 1 < megas.count {
            var a = Partner(seed: UInt64(index + 1))
            a.digimonID = left.id
            a.stage = .ultimate
            var b = Partner(seed: UInt64(index + 100))
            b.digimonID = megas[index + 1].id
            b.stage = .ultimate
            if Digivolution.jogress(a, b) != nil { fusions += 1 }
        }
        expect(fusions == megas.count - 1, "every Mega pair fuses (\(fusions)/\(megas.count - 1))")
    }

    static func testCare() {
        var lean = CareProfile()
        lean.weight = 20
        lean.discipline = 90
        lean.careMistakes = 0
        expect(CareEngine.attribute(for: lean) == .vaccine, "disciplined and lean reads Vaccine")

        var night = CareProfile()
        night.nocturnal = 0.9
        night.careMistakes = 8
        night.weight = 80
        expect(CareEngine.attribute(for: night) == .virus, "nocturnal and neglectful reads Virus")

        // Quiet but clean: no night work, very cache-efficient, just sporadic.
        // That is an absence of signal, not a Virus tamer.
        var sporadic = CareProfile()
        sporadic.weight = 13
        sporadic.discipline = 38
        sporadic.careMistakes = 6
        sporadic.nocturnal = 0.05
        expect(
            CareEngine.attribute(for: sporadic) != .virus,
            "a quiet but efficient fortnight is not Virus (got \(CareEngine.attribute(for: sporadic).rawValue))"
        )

        // The same neglect plus real Virus signals should tip it over.
        var sporadicNocturnal = sporadic
        sporadicNocturnal.nocturnal = 0.8
        sporadicNocturnal.weight = 80
        expect(
            CareEngine.attribute(for: sporadicNocturnal) == .virus,
            "neglect combined with night work reads Virus"
        )

        let base = CareEngine.xAntibodyChance(profile: CareProfile(), hasCharm: false)
        var disciplined = CareProfile(); disciplined.discipline = 100
        let better = CareEngine.xAntibodyChance(profile: disciplined, hasCharm: false)
        expect(better > base, "consistency improves X-Antibody odds")
        expect(base < 0.02, "base X-Antibody odds stay rare (\(String(format: "%.4f", base)))")

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Worked every day of the window: nothing to answer for.
        let diligent = Set((0..<14).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) })
        expect(
            CareEngine.neglectedDays(activeDays: diligent, now: Date(), calendar: calendar) == 0,
            "a fully worked fortnight carries no neglect"
        )

        // Two days worked out of fourteen: twelve idle, four forgiven.
        let sparse = Set([0, 5].compactMap { calendar.date(byAdding: .day, value: -$0, to: today) })
        let neglected = CareEngine.neglectedDays(activeDays: sparse, now: Date(), calendar: calendar)
        expect(neglected == 8, "twelve idle days minus grace is eight (got \(neglected))")

        // Ancient history must not follow a new partner around.
        let longAgo = Set(
            (200..<260).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        ).union(diligent)
        expect(
            CareEngine.neglectedDays(activeDays: longAgo, now: Date(), calendar: calendar) == 0,
            "idle months before the window do not count"
        )

        // A weekend off should not tip a tamer into Virus.
        var weekender = CareProfile()
        weekender.weight = 25
        weekender.discipline = 45
        weekender.careMistakes = CareEngine.neglectedDays(
            activeDays: Set((0..<10).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }),
            now: Date(), calendar: calendar
        )
        expect(
            CareEngine.attribute(for: weekender) != .virus,
            "taking weekends off does not read as neglect"
        )

        // Overwork is judged against the tamer's own norm, not an absolute.
        let calm = (0..<8).map { _ in makeBlock(500_000) }
        expect(CareEngine.overworkedWindows(calm) == 0, "steady windows are not overwork")
        let spiky = (0..<8).map { _ in makeBlock(500_000) } + [makeBlock(9_000_000)]
        expect(CareEngine.overworkedWindows(spiky) == 1, "one runaway window is flagged")
        let tiny = (0..<8).map { _ in makeBlock(1_000) } + [makeBlock(50_000)]
        expect(
            CareEngine.overworkedWindows(tiny) == 0,
            "a light user's busiest afternoon is not a binge"
        )
    }

    static func makeBlock(_ billable: Int) -> UsageBlock {
        let start = Date().addingTimeInterval(-6 * 3600)
        return UsageBlock(
            start: start,
            end: start.addingTimeInterval(UsageAggregator.blockDuration),
            counts: TokenCounts(input: billable, output: 0, cacheCreation: 0, cacheRead: 0),
            lastActivity: start
        )
    }

    // MARK: - Real data

    static func testRetention() {
        let calendar = Calendar.current
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "digi-retention-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        // A file the cache has never seen; the path only has to be stable.
        let path = "/tmp/does-not-exist-\(UUID()).jsonl"
        let cache = ScanCache(url: url, calendar: calendar)

        let old = Date().addingTimeInterval(-Double(ScanCache.retentionDays + 30) * 86400)
        let recent = Date().addingTimeInterval(-3600)
        let events = [
            UsageEvent(
                timestamp: old, model: "m",
                counts: TokenCounts(input: 1_000, output: 0, cacheCreation: 0, cacheRead: 0),
                dedupKey: "old", sessionID: "s-old", project: nil
            ),
            UsageEvent(
                timestamp: recent, model: "m",
                counts: TokenCounts(input: 500, output: 0, cacheCreation: 0, cacheRead: 0),
                dedupKey: "new", sessionID: "s-new", project: nil
            ),
        ]
        cache.record(path: path, offset: 100, newEvents: events)

        let retained = cache.cachedEvents(for: path)
        expect(retained.count == 1, "events past retention are dropped from the cache")
        expect(retained.first?.dedupKey == "new", "the recent event is the one kept")

        let archive = cache.archive
        expect(archive.counts.input == 1_000, "the aged-out event survives in the archive")
        expect(archive.eventCount == 1, "the archive counts what it absorbed")
        expect(archive.sessions.contains("s-old"), "archived sessions are remembered")

        // The rollup must still report the full history despite the pruning.
        let usage = UsageAggregator.summarize(
            provider: .claudeCode, events: retained, archive: archive
        )
        expect(usage.allTime.input == 1_500, "all-time spans archive and retained events")
        expect(usage.sessionCount == 2, "session count spans both")
        expect(usage.activeDays.count == 2, "active days span both")
        expect(usage.today.input == 500, "today counts only the recent event")
    }

    /// digi-api paints almost every Digimon on a solid white card, which reads as
    /// a white rectangle on the app's dark panel. The fill has to remove the card
    /// without eating white *inside* the artwork — Angemon's wings and Zurumon's
    /// eye highlights are the cases that break a naive brightness threshold.
    static func testSpriteProcessing() {
        // A white card, a dark ring, and a white core inside the ring.
        let size = 80
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 20, y: 20, width: 40, height: 40)).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 32, y: 32, width: 16, height: 16)).fill()
        image.unlockFocus()

        let processed = SpriteProcessor.process(image)
        guard let sampler = PixelSampler(processed) else {
            expect(false, "processed image is readable")
            return
        }

        expect(
            sampler.alpha(atFraction: 0.02, 0.02) < 16,
            "the background card is removed from the corners"
        )
        expect(
            sampler.alpha(atFraction: 0.5, 0.5) > 200,
            "white enclosed by the artwork survives"
        )
        expect(
            processed.size.width < image.size.width || processed.size.height < image.size.height,
            "the result is cropped to the artwork (\(Int(processed.size.width))x\(Int(processed.size.height)))"
        )

        // An image that is already a cut-out must be trimmed, not re-keyed.
        let cutout = NSImage(size: NSSize(width: size, height: size))
        cutout.lockFocus()
        NSColor.white.withAlphaComponent(1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 30, y: 30, width: 20, height: 20)).fill()
        cutout.unlockFocus()
        let trimmed = SpriteProcessor.process(cutout)
        expect(
            trimmed.size.width < 40 && trimmed.size.height < 40,
            "an existing cut-out is trimmed to its content (\(Int(trimmed.size.width))x\(Int(trimmed.size.height)))"
        )
    }

    /// Minimal RGBA reader, so the checks above can talk about pixels.
    struct PixelSampler {
        let buffer: [UInt8]
        let width: Int
        let height: Int

        init?(_ image: NSImage) {
            var rect = NSRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            else { return nil }
            width = cg.width
            height = cg.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            buffer = pixels
        }

        func alpha(atFraction x: Double, _ y: Double) -> Int {
            let px = min(width - 1, max(0, Int(Double(width) * x)))
            let py = min(height - 1, max(0, Int(Double(height) * y)))
            return Int(buffer[(py * width + px) * 4 + 3])
        }
    }

    static func testRealLogs() async {
        var found = false

        for provider in [ClaudeCodeProvider() as any UsageProvider, CodexProvider()] {
            // A fresh cache each run, so the timings below measure a real cold
            // scan rather than whatever a previous run left behind.
            let cacheURL = URL(
                fileURLWithPath: NSTemporaryDirectory() + "digitest-\(provider.id.rawValue).json"
            )
            try? FileManager.default.removeItem(at: cacheURL)
            let cache = ScanCache(url: cacheURL)
            guard provider.isAvailable() else {
                print("  skip \(provider.id.displayName): not installed")
                continue
            }
            let start = Date()
            let events = provider.scan(cache: cache)
            let elapsed = Date().timeIntervalSince(start)
            guard !events.isEmpty else {
                print("  skip \(provider.id.displayName): no events on disk")
                continue
            }
            found = true

            let usage = UsageAggregator.summarize(provider: provider.id, events: events)
            print("""
                  \(provider.id.displayName): \(events.count) events, \
                  \(TokenFormatter.short(usage.allTime.billable)) billable, \
                  \(TokenFormatter.short(usage.allTime.total)) total, \
                  \(usage.sessionCount) sessions, \(usage.activeDays.count) active days \
                  (\(String(format: "%.2f", elapsed))s)
                  """)
            expect(usage.allTime.billable > 0, "\(provider.id.displayName): billable tokens found")
            expect(
                usage.allTime.total >= usage.allTime.billable,
                "\(provider.id.displayName): totals are consistent"
            )
            expect(elapsed < 20, "\(provider.id.displayName): cold scan under 20s")

            // The second scan must reuse the cache rather than re-reading bytes.
            let warmStart = Date()
            let warm = provider.scan(cache: cache)
            let warmElapsed = Date().timeIntervalSince(warmStart)
            expect(
                warm.count == events.count,
                "\(provider.id.displayName): warm scan returns the same events"
            )
            expect(
                warmElapsed < elapsed || warmElapsed < 0.5,
                "\(provider.id.displayName): warm scan is cheaper (\(String(format: "%.2f", warmElapsed))s)"
            )
        }

        if !found {
            print("  (no local AI-tool logs found — parser checks above still ran)")
        }
    }
}
