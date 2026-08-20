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

        section("Project breakdown")
        testProjectBreakdown()

        section("Growth pace")
        testGrowthPace()

        section("Shop")
        testShop()

        section("Save compatibility")
        testSaveCompatibility()

        section("Coach")
        testCoach()

        section("Tamer cards")
        await testTamerCards()

        section("Rarity stars")
        testRarityStars()

        section("Collection")
        testCollection()

        section("Dex detail")
        testDexDetail()

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

        let now = Date()
        let old = now.addingTimeInterval(-Double(ScanCache.retentionDays + 30) * 86400)
        // Clamped to today rather than simply an hour back: run this in the
        // first hour after midnight and "an hour ago" lands yesterday, and the
        // check below that today counts it fails for a reason that has nothing
        // to do with retention.
        let recent = max(calendar.startOfDay(for: now), now.addingTimeInterval(-3600))
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

        // `size` is in points and the crop is measured in pixels. `lockFocus` on
        // a Retina display backs an 80-point image with 160 pixels, so returning
        // the pixel count as the size would declare every sprite twice its real
        // size — which is what made the crop check above read as "larger than
        // the input". Pin the ratio, not just the direction.
        expect(
            abs(Double(sampler.width) / processed.size.width - backingScale(of: image)) < 0.01,
            "the processed sprite keeps the source's pixels-per-point"
                + " (\(sampler.width)px over \(Int(processed.size.width))pt)"
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

    /// Pixels per point of an image's backing store, which is 2 for anything
    /// drawn with `lockFocus` on a Retina display and 1 for a plain decode.
    static func backingScale(of image: NSImage) -> Double {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              image.size.width > 0
        else { return 1 }
        return Double(cg.width) / Double(image.size.width)
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
            Int(rgba(atFraction: x, y).3)
        }

        func rgba(atFraction x: Double, _ y: Double) -> (Int, Int, Int, Int) {
            let px = min(width - 1, max(0, Int(Double(width) * x)))
            let py = min(height - 1, max(0, Int(Double(height) * y)))
            let index = (py * width + px) * 4
            return (
                Int(buffer[index]), Int(buffer[index + 1]),
                Int(buffer[index + 2]), Int(buffer[index + 3])
            )
        }
    }

    /// The shop's one rule is that an item is bought before the outcome is
    /// known and never applied in hindsight. These checks pin the parts of that
    /// rule the code can actually enforce.
    /// Saves must survive the model gaining fields.
    ///
    /// This is a regression test for a real loss: adding `preferredField` and
    /// `xVialActive` to `Partner` made every existing save undecodable, because
    /// Swift's synthesized decoder calls `decode` for non-optional properties
    /// and ignores their defaults. The store read that as "no save" and started
    /// a fresh egg, wiping a partner that had been growing for days.
    static func testSaveCompatibility() {
        // Exactly the shape a save had before the shop existed.
        let legacy = """
        {"id":"603328E8-6639-4FC4-8C60-38E5D82CAB78","seed":18142757285949799043,
         "digimonID":97,"stage":1,"bornAt":808851098.4,"tokens":271557,
         "isXAntibody":false,"lineage":[97,144],"digivolutionDates":[],
         "careMistakes":6,"caredDays":0}
        """
        guard let partner = try? JSONDecoder().decode(Partner.self, from: Data(legacy.utf8)) else {
            expect(false, "a save written before the shop existed still decodes")
            return
        }
        expect(partner.seed == 18_142_757_285_949_799_043, "the seed survives")
        expect(partner.lineage == [97, 144], "the lineage survives")
        expect(partner.tokens == 271_557, "the token total survives")
        expect(partner.preferredField == nil, "a field added later defaults cleanly")
        expect(partner.xVialActive == false, "a flag added later defaults cleanly")

        // The absolute minimum: a partner is identified by its seed, and the
        // engine is deterministic, so seed alone is enough to rebuild one.
        let minimal = #"{"seed":18142757285949799043}"#
        let rebuilt = try? JSONDecoder().decode(Partner.self, from: Data(minimal.utf8))
        expect(rebuilt?.seed == 18_142_757_285_949_799_043, "a seed alone is a valid save")

        // And determinism means that rebuild produces the same partner, which is
        // what made recovering from the wipe possible at all.
        let a = Digivolution.hatch(seed: 18_142_757_285_949_799_043, profile: CareProfile())
        let b = Digivolution.hatch(seed: 18_142_757_285_949_799_043, profile: CareProfile())
        expect(a?.entry.id == b?.entry.id, "the same seed rebuilds the same partner")

        // A wallet written before DNA charges existed. `Wallet` is held by
        // `SaveFile`, so a wallet that will not decode takes the partner with
        // it — the exact failure this project has already paid for once.
        // Note the inventory shape: a dictionary keyed by an enum encodes as a
        // flat array, which is what is actually on disk.
        let oldWallet = #"""
        {"baseline":10,"hasBaseline":true,"spent":5,"earned":900,
         "inventory":["streakFreeze",2]}
        """#
        let wallet = try? JSONDecoder().decode(Wallet.self, from: Data(oldWallet.utf8))
        expect(wallet?.earned == 900, "a wallet saved before charges existed still decodes")
        expect(wallet?.stock(of: .streakFreeze) == 2, "its inventory survives")
        expect(wallet?.dna.stock == 0, "the charge meter added later defaults cleanly")

        // A save missing the seed is genuinely unreadable and must fail loudly
        // rather than decode into a partner with a zero seed.
        let broken = #"{"tokens":100}"#
        expect(
            (try? JSONDecoder().decode(Partner.self, from: Data(broken.utf8))) == nil,
            "a save with no seed is rejected rather than silently invented"
        )
    }

    static func testShop() {
        var wallet = Wallet()
        wallet.update(allTimeBillable: 5_000_000)
        expect(wallet.balance == 0, "a fresh wallet starts empty, not with the whole log history")

        wallet.update(allTimeBillable: 5_600_000)
        expect(wallet.balance == 600_000, "currency accrues from work done after install")

        // Logs can be pruned; the balance must not go negative.
        wallet.update(allTimeBillable: 100_000)
        expect(wallet.balance >= 0, "a shrinking log re-anchors instead of going negative")

        var funded = Wallet()
        funded.update(allTimeBillable: 0)
        funded.update(allTimeBillable: 10_000_000)
        let compass = ShopItem.item(.fieldCompass)
        expect(funded.canAfford(compass), "affordability compares against the balance")
        funded.spent = funded.earned
        expect(!funded.canAfford(compass), "spending everything ends affordability")

        // DNA charges: earned by work, capped, and never refilled by the clock.
        var dna = DNACharge()
        dna.accrue(earned: DNACharge.tokensPerCharge - 1)
        expect(dna.stock == 0, "a charge is not handed over before the work is done")
        expect(
            dna.tokensToNext == 1,
            "the meter reports what is left (\(dna.tokensToNext))"
        )
        dna.accrue(earned: DNACharge.tokensPerCharge)
        expect(dna.stock == 1, "the charge lands on the token that earns it")

        // The same tokens must not be counted twice: `accrue` is called on
        // every refresh, and a refresh that found no new work is the common case.
        dna.accrue(earned: DNACharge.tokensPerCharge)
        dna.accrue(earned: DNACharge.tokensPerCharge)
        expect(dna.stock == 1, "an idle refresh does not mint charges")

        // Time is deliberately not an input. Nothing here can move the meter
        // except tokens, and this is the check that says so.
        dna.accrue(earned: DNACharge.tokensPerCharge * 12)
        expect(dna.stock == DNACharge.cap, "the meter stops at the cap (\(dna.stock))")
        expect(dna.progress == 0, "a full meter banks nothing against the next charge")
        expect(dna.spend(), "a held charge can be spent")
        expect(dna.stock == DNACharge.cap - 1, "spending takes exactly one")

        // A tamer already using the app when charges arrived has done the work
        // and gets credit for it rather than starting from zero.
        var adopted = DNACharge()
        adopted.accrue(earned: DNACharge.tokensPerCharge * 2)
        expect(adopted.stock == 2, "an existing wallet is credited for work already done")

        // Pruned logs re-anchor the wallet downward; that must not pay out again
        // on the way back up.
        var reanchored = DNACharge()
        reanchored.accrue(earned: DNACharge.tokensPerCharge * 2)
        reanchored.accrue(earned: 0)
        reanchored.accrue(earned: DNACharge.tokensPerCharge)
        expect(reanchored.stock == 2, "a re-anchored wallet does not pay twice")

        var empty = DNACharge()
        expect(!empty.spend(), "an empty meter cannot be spent")

        // Buying is capped by the same ceiling the meter is.
        var stocked = Wallet()
        stocked.update(allTimeBillable: 0)
        stocked.update(allTimeBillable: 40_000_000)
        stocked.dna.stock = DNACharge.cap
        expect(
            stocked.stock(of: .dnaCharge) == DNACharge.cap,
            "the shop row counts the meter, not the inventory"
        )

        // Nothing in the catalogue may undo the past. This is the rule the whole
        // design rests on, so it is asserted rather than left to review.
        let names = ShopItem.catalogue.map(\.name).joined(separator: " ").lowercased()
        expect(
            !names.contains("medicine") && !names.contains("candy"),
            "no item clears a care mistake or skips a rung"
        )
        expect(ShopItem.catalogue.allSatisfy { $0.price > 0 }, "every item costs something")

        // A compass has to actually move the branch, or it is decoration.
        var profile = CareProfile()
        profile.attribute = .free
        var steered = 0
        var attempted = 0
        for entry in DigiDex.shared.entries(stage: .child).prefix(60) {
            let plain = Digivolution.next(
                from: entry, to: .adult, seed: 5, profile: profile, wantsXAntibody: false
            )
            let aimed = Digivolution.next(
                from: entry, to: .adult, seed: 5, profile: profile,
                wantsXAntibody: false, preferredField: "Nature Spirits"
            )
            guard let plain, let aimed else { continue }
            attempted += 1
            if plain.entry.id != aimed.entry.id { steered += 1 }
        }
        expect(steered > 10, "a compass changes the branch (\(steered)/\(attempted) differ)")

        // When the pool can honour a compass, it is guaranteed — not merely
        // favoured. Paying and then watching the roll ignore you is the one
        // outcome the item must never produce.
        var honoured = 0
        var offered = 0
        for entry in DigiDex.shared.entries(stage: .child).prefix(40) {
            guard let result = Digivolution.next(
                from: entry, to: .adult, seed: 9, profile: profile,
                wantsXAntibody: false, preferredField: "Deep Savers"
            ) else { continue }
            guard result.consumedField else { continue }
            offered += 1
            if result.entry.fields.contains("Deep Savers") { honoured += 1 }
        }
        expect(
            offered > 0 && honoured == offered,
            "a spent compass always lands in its field (\(honoured)/\(offered))"
        )

        // A field the target rung cannot supply must leave the compass unspent
        // rather than silently consuming it.
        let unusable = Digivolution.next(
            from: DigiDex.shared.entries(stage: .child)[0], to: .adult, seed: 3,
            profile: profile, wantsXAntibody: false,
            preferredField: "Not A Real Field"
        )
        expect(
            unusable != nil && unusable?.consumedField == false,
            "an unhonourable compass is kept for the next rung"
        )

        // Streak freezes cover the gaps nearest today, never today itself.
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ back: Int) -> Date {
            calendar.date(byAdding: .day, value: -back, to: today)!
        }
        let active: Set<Date> = [day(0), day(1), day(4), day(5)]
        let chosen = CareEngine.daysToFreeze(
            activeDays: active, alreadyFrozen: [], available: 2
        )
        expect(chosen.count == 2, "two freezes cover two gaps (got \(chosen.count))")
        expect(!chosen.contains(today), "today is never frozen — the day is not over")
        expect(chosen.contains(day(2)) && chosen.contains(day(3)), "the nearest gaps are covered first")

        let none = CareEngine.daysToFreeze(activeDays: active, alreadyFrozen: [], available: 0)
        expect(none.isEmpty, "no stock means no freezing")

        // A frozen day has to actually rescue the streak and the neglect count.
        let bare = UsageAggregator.streak(activeDays: Array(active))
        let rescued = UsageAggregator.streak(
            activeDays: Array(active), frozenDays: Set(chosen)
        )
        expect(rescued > bare, "freezing extends the streak (\(bare) -> \(rescued))")

        let neglectBefore = CareEngine.neglectedDays(
            activeDays: active, now: Date(), calendar: calendar
        )
        let neglectAfter = CareEngine.neglectedDays(
            activeDays: active, frozenDays: Set(chosen), now: Date(), calendar: calendar
        )
        expect(neglectAfter <= neglectBefore, "freezing never increases neglect")
    }

    static func testProjectBreakdown() {
        func event(_ project: String?, _ tokens: Int, hoursAgo: Double, key: String) -> UsageEvent {
            UsageEvent(
                timestamp: Date().addingTimeInterval(-hoursAgo * 3600),
                model: "claude-sonnet-5",
                counts: TokenCounts(input: tokens, output: 0, cacheCreation: 0, cacheRead: 0),
                dedupKey: key, sessionID: "s", project: project
            )
        }

        let events = [
            event("alpha", 500, hoursAgo: 1, key: "a"),
            event("alpha", 300, hoursAgo: 2, key: "b"),
            event("beta", 900, hoursAgo: 3, key: "c"),
            // No project recorded; must not create a phantom row.
            event(nil, 100, hoursAgo: 4, key: "d"),
        ]
        let usage = UsageAggregator.summarize(provider: .claudeCode, events: events)

        expect(usage.projects.count == 2, "only projects with a recorded directory appear")
        expect(usage.projects.first?.name == "beta", "biggest consumer sorts first")
        expect(usage.projects.first?.counts.billable == 900, "per-project totals add up")
        expect(
            usage.projects.first(where: { $0.name == "alpha" })?.counts.billable == 800,
            "events for the same project are combined"
        )
        expect(
            usage.allTime.billable == 1_800,
            "the untracked event still counts toward the total"
        )

        // The breakdown has to survive the cache ageing events out.
        var archive = UsageArchive()
        archive.absorb(event("alpha", 4_000, hoursAgo: 5_000, key: "old"), calendar: .current)
        let spanning = UsageAggregator.summarize(
            provider: .claudeCode, events: events, archive: archive
        )
        expect(
            spanning.projects.first?.name == "alpha",
            "archived project totals are folded back in"
        )
        expect(
            spanning.projects.first?.counts.billable == 4_800,
            "archived and retained totals combine per project"
        )

        // Codex names its directory in separate header records.
        let meta = #"{"type":"session_meta","payload":{"cwd":"/Users/x/dev/red-flag"}}"#
        expect(
            CodexProvider.workingDirectory(in: Data(meta.utf8)) == "/Users/x/dev/red-flag",
            "codex: session_meta yields the working directory"
        )
        let turn = #"{"type":"turn_context","cwd":"/Users/x/dev/other"}"#
        expect(
            CodexProvider.workingDirectory(in: Data(turn.utf8)) == "/Users/x/dev/other",
            "codex: an unnested turn_context also yields it"
        )
        let usageLine = #"{"type":"event_msg","payload":{"type":"token_count"}}"#
        expect(
            CodexProvider.workingDirectory(in: Data(usageLine.utf8)) == nil,
            "codex: usage records carry no directory"
        )
    }

    static func testGrowthPace() {
        let quick = GrowthCurve.requirement(for: .ultimate, pace: .quick)
        let standard = GrowthCurve.requirement(for: .ultimate, pace: .standard)
        let marathon = GrowthCurve.requirement(for: .ultimate, pace: .marathon)

        expect(quick < standard && standard < marathon, "the paces are ordered")
        expect(standard == 8_000_000, "Mega sits at 8M billable on the default pace")
        expect(quick == 4_000_000, "light use halves it")

        // Every rung must still be strictly increasing at every pace, or the
        // ladder could grant two stages for the same token.
        for pace in GrowthPace.allCases {
            var previous = -1
            var monotonic = true
            for stage in DigiStage.allCases {
                let value = GrowthCurve.requirement(for: stage, pace: pace)
                if value <= previous && stage != .babyI { monotonic = false }
                previous = value
            }
            expect(monotonic, "\(pace.label): thresholds increase at every rung")
        }

        // Progress has to stay inside 0...1 whatever the pace.
        let progress = GrowthCurve.progress(tokens: 500_000, stage: .child, pace: .marathon)
        expect((0...1).contains(progress), "progress stays bounded (\(progress))")
    }

    /// The coach has to stay quiet at a tamer who is already working well.
    ///
    /// Thresholds were set against the real profile on the machine this was
    /// written on — 97% cache share, 43x amortisation, a 400K median session —
    /// and the point of pinning it here is that a future retune cannot start
    /// nagging that tamer without a test going red.
    static func testCoach() {
        func event(
            model: String, session: String, key: String,
            input: Int = 0, output: Int = 0, write: Int = 0, read: Int = 0
        ) -> UsageEvent {
            UsageEvent(
                timestamp: Date(),
                model: model,
                counts: TokenCounts(
                    input: input, output: output, cacheCreation: write, cacheRead: read
                ),
                dedupKey: key,
                sessionID: session,
                project: "demo"
            )
        }

        func fired(_ report: CoachReport, _ id: String) -> Bool {
            report.advice.contains { $0.id == id }
        }

        // Not enough history to describe a habit.
        let thin = (0..<3).map {
            event(model: "claude-opus-5", session: "s\($0)", key: "k\($0)", input: 1_000, output: 500)
        }
        let thinReport = Coach.report(events: thin)
        expect(thinReport.isTooEarly, "three sessions is too early to advise")
        expect(thinReport.advice.isEmpty, "nothing is claimed before there is data")

        // The shape of a tamer who works well: heavy cache reuse, long sessions.
        let healthy = (0..<12).map {
            event(
                model: "claude-opus-5", session: "s\($0)", key: "h\($0)",
                input: 20_000, output: 150_000, write: 750_000, read: 32_000_000
            )
        }
        let healthyReport = Coach.report(events: healthy)
        expect(!healthyReport.isTooEarly, "twelve busy sessions is enough to judge")
        expect(
            healthyReport.advice.isEmpty,
            "an efficient tamer is left alone (got \(healthyReport.advice.map(\.id)))"
        )
        expect(
            healthyReport.cacheShare > 0.9,
            "the basis is reported even with no advice (\(Int(healthyReport.cacheShare * 100))% cache)"
        )

        // Context re-sent rather than reused.
        let wasteful = (0..<12).map {
            event(
                model: "claude-opus-5", session: "s\($0)", key: "w\($0)",
                input: 900_000, output: 100_000, write: 50_000, read: 100_000
            )
        }
        expect(fired(Coach.report(events: wasteful), "cache-reuse"), "low cache reuse is flagged")

        // Cache written every session and never read back.
        let churn = (0..<12).map {
            event(
                model: "claude-opus-5", session: "s\($0)", key: "c\($0)",
                input: 30_000, output: 20_000, write: 800_000, read: 400_000
            )
        }
        let churnReport = Coach.report(events: churn)
        expect(fired(churnReport, "cache-amortisation"), "cache that never pays back is flagged")
        expect(
            churnReport.amortisation < Coach.amortisationFloor,
            "the amortisation figure backs the claim (\(String(format: "%.1f", churnReport.amortisation)))"
        )

        // Short sessions whose spend went almost entirely on setup.
        let stubby = (0..<40).map {
            event(
                model: "claude-opus-5", session: "s\($0)", key: "t\($0)",
                input: 2_000, output: 1_000, write: 30_000, read: 40_000
            )
        }
        expect(fired(Coach.report(events: stubby), "session-length"), "short costly sessions are flagged")

        // Small sessions that are simply small — no setup cost being wasted —
        // must not be flagged. Not every short task is a mistake.
        let smallButClean = (0..<40).map {
            event(
                model: "claude-opus-5", session: "s\($0)", key: "n\($0)",
                input: 4_000, output: 12_000, write: 0, read: 900_000
            )
        }
        expect(
            !fired(Coach.report(events: smallButClean), "session-length"),
            "a short session with no wasted setup is left alone"
        )

        // Everything on the expensive model while a cheaper one sits idle.
        var lopsided = (0..<12).map {
            event(
                model: "claude-opus-5", session: "s\($0)", key: "m\($0)",
                input: 40_000, output: 200_000, write: 400_000, read: 20_000_000
            )
        }
        lopsided.append(
            event(
                model: "claude-haiku-4-5", session: "s0", key: "mh",
                input: 500, output: 500, write: 0, read: 5_000
            )
        )
        expect(fired(Coach.report(events: lopsided), "model-mix"), "an idle cheap model is flagged")

        // A tamer who already spreads work across models is not lectured.
        var balanced = (0..<8).map {
            event(
                model: "claude-opus-5", session: "s\($0)", key: "b\($0)",
                input: 20_000, output: 60_000, write: 200_000, read: 12_000_000
            )
        }
        balanced += (0..<8).map {
            event(
                model: "claude-haiku-4-5", session: "sh\($0)", key: "bh\($0)",
                input: 60_000, output: 200_000, write: 600_000, read: 12_000_000
            )
        }
        expect(
            !fired(Coach.report(events: balanced), "model-mix"),
            "a tamer already using cheaper models is left alone"
        )

        // Two tools, two habits. The coach is scoped to one tool at a time
        // because a report over the union describes neither: here the cache
        // reads from the tool that is used well swamp the one that is not, and
        // the advice that should fire disappears. It was appearing under the
        // wrong tab before, which is the same bug seen from the other side.
        let secondTool = (0..<12).map {
            event(
                model: "claude-opus-5", session: "x\($0)", key: "x\($0)",
                input: 900_000, output: 100_000, write: 50_000, read: 100_000
            )
        }
        expect(
            fired(Coach.report(events: secondTool), "cache-reuse"),
            "a tool used wastefully is flagged on its own events"
        )
        expect(
            !fired(Coach.report(events: healthy + secondTool), "cache-reuse"),
            "pooling both tools hides it — which is why the pane reports per tool"
        )

        // Forked transcripts repeat the same turn; counting them would inflate
        // every share the coach reports.
        let doubled = healthy + healthy
        let deduped = Coach.report(events: doubled)
        expect(
            deduped.billable == healthyReport.billable,
            "duplicate events do not inflate the report"
        )
        expect(
            deduped.sessions == healthyReport.sessions,
            "duplicate events do not inflate the session count"
        )

        // Every claim has to carry a figure, or it cannot be checked.
        let all = [wasteful, churn, stubby, lopsided].flatMap { Coach.report(events: $0).advice }
        expect(!all.isEmpty, "the rules produce advice at all (\(all.count) items)")
        expect(
            all.allSatisfy { !$0.evidence.isEmpty && !$0.title.isEmpty && !$0.detail.isEmpty },
            "no advice ships without its evidence"
        )
    }

    /// The card is the only thing in this app that ever leaves the machine, so
    /// what it carries and what it refuses are both worth pinning.
    @MainActor
    static func testTamerCards() async {
        func card(
            tamer: String, seed: UInt64, id: Int, stage: DigiStage = .ultimate
        ) -> TamerCard {
            TamerCard(
                tamer: tamer, seed: seed, digimonID: id, stage: stage,
                isXAntibody: false, lineage: [id], nickname: nil, tokens: 8_000_000,
                attribute: .vaccine, streak: 12, careMistakes: 0,
                dexSeen: 40, dexTotal: DigiDex.shared.all.count
            )
        }

        guard let sample = DigiDex.shared.entries(stage: .ultimate).first else {
            expect(false, "the dex has an Ultimate to build a card from")
            return
        }
        let mine = card(tamer: "Ada", seed: 12_345, id: sample.id)
        let code = TamerCardCodec.encode(mine)

        expect(code.hasPrefix("\(TamerCardCodec.prefix)."), "a card is recognisable on sight")
        expect(code.count < 700, "a card fits in a chat message (\(code.count) chars)")

        let round = try? TamerCardCodec.decode(code)
        expect(round?.seed == mine.seed, "the seed survives the round trip")
        expect(round?.digimonID == mine.digimonID, "the partner survives the round trip")
        expect(round?.tamer == "Ada", "the tamer name survives the round trip")
        expect(round?.stage == mine.stage, "the stage survives the round trip")

        // Chat clients wrap long strings. A card that only works when pasted
        // perfectly is a card that mostly does not work.
        let wrapped = code.prefix(40) + "\n  " + code.dropFirst(40)
        expect(
            (try? TamerCardCodec.decode(String(wrapped)))?.seed == mine.seed,
            "a card survives being wrapped across lines"
        )

        // The failure that matters: a truncated card must not decode into some
        // other partner. It has to be refused.
        let truncated = String(code.dropLast(12))
        var damaged = false
        do { _ = try TamerCardCodec.decode(truncated) } catch { damaged = true }
        expect(damaged, "a truncated card is refused rather than misread")

        var notACard = false
        do { _ = try TamerCardCodec.decode("hello there") } catch { notACard = true }
        expect(notACard, "arbitrary clipboard text is not a card")

        // A friend on a newer build must not hand over something unreadable, so
        // everything past the fields a fusion needs is optional.
        let sparse = #"{"seed":999,"digimonID":\#(sample.id)}"#
        let lenient = try? JSONDecoder().decode(TamerCard.self, from: Data(sparse.utf8))
        expect(lenient?.seed == 999, "a card missing every optional field still decodes")
        expect(lenient?.tamer == "Tamer", "a nameless card gets a neutral name")

        // What the card does *not* carry is the point of the format.
        guard let payload = code.split(separator: ".").dropFirst().first,
              let json = decodeBase64url(String(payload)),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else {
            expect(false, "the card payload is readable JSON")
            return
        }
        let allowed: Set<String> = [
            "version", "tamer", "issuedAt", "seed", "digimonID", "stage",
            "isXAntibody", "lineage", "nickname", "tokens", "attribute",
            "streak", "careMistakes", "dexSeen", "dexTotal",
        ]
        let extra = Set(object.keys).subtracting(allowed)
        expect(extra.isEmpty, "the card carries nothing beyond the partner (\(extra.sorted()))")

        // MARK: Jogress across two tamers

        // Built by writing a save and loading it, so the collection arrives
        // through the same decode path a real one does rather than through a
        // hatch put there for the test's convenience.
        var graduated = Partner(seed: 555)
        graduated.digimonID = sample.id
        graduated.stage = .ultimate
        graduated.lineage = [sample.id]
        graduated.retiredAt = Date()

        func makeStore(collection: [Partner], charges: Int = 1) -> PartnerStore? {
            let url = URL(
                fileURLWithPath: NSTemporaryDirectory() + "digitest-cards-\(UUID()).json"
            )
            var seed = Partner(seed: 4_242)
            seed.digimonID = sample.id
            seed.stage = .adult
            var wallet = Wallet()
            wallet.dna.stock = charges
            let file = PartnerStore.SaveFile(
                partner: seed, collection: collection, seenDigimon: [sample.id],
                seenXAntibody: [], baseline: 0, hasBaseline: true, profile: nil, wallet: wallet
            )
            guard let data = try? JSONEncoder().encode(file),
                  (try? data.write(to: url, options: .atomic)) != nil
            else { return nil }
            return PartnerStore(storeURL: url)
        }

        guard let store = makeStore(collection: []) else {
            expect(false, "a store can be built from a written save")
            return
        }

        expect(store.importCard("not a card") == .rejected(.notACard), "junk is not imported")

        let friend = card(tamer: "Grace", seed: 777, id: sample.id)
        let friendCode = TamerCardCodec.encode(friend)
        expect(store.importCard(friendCode) == .imported("Grace"), "a friend's card is imported")
        expect(store.friends.count == 1, "the friend is remembered")

        // Re-importing the same friend after they digivolve replaces their card
        // rather than stacking a second one beside it.
        expect(store.importCard(friendCode) == .imported("Grace"), "re-importing is allowed")
        expect(store.friends.count == 1, "re-importing replaces rather than duplicates")

        // Fusing with yourself is not a Jogress.
        if let ownCard = store.myCard(name: "Me") {
            let own = TamerCardCodec.encode(ownCard)
            expect(store.importCard(own) == .ownCard, "your own card is refused")
        }

        // With nothing graduated there is nothing to spend.
        expect(
            store.jogress(graduated, with: friend) == .notInCollection,
            "a partner outside the collection cannot be spent"
        )

        // A Jogress costs a DNA Charge, and an empty meter must cost nothing
        // else. The partner it would have spent has to still be there.
        guard let unfunded = makeStore(collection: [graduated], charges: 0) else {
            expect(false, "a store with no charges can be built")
            return
        }
        unfunded.importCard(friendCode)
        expect(
            unfunded.jogress(graduated, with: friend) == .noCharge,
            "a Jogress without a DNA Charge is refused"
        )
        expect(
            unfunded.collection.contains { $0.id == graduated.id },
            "the refused Jogress consumed nothing"
        )

        // The real path: a graduated partner fuses and is consumed.
        guard let fusing = makeStore(collection: [graduated]) else {
            expect(false, "a store with a collection can be built")
            return
        }
        fusing.importCard(friendCode)
        let before = fusing.collection.count
        let result = fusing.jogress(graduated, with: friend)
        guard case .fused(let name) = result else {
            expect(false, "a graduated partner fuses with a visiting one (got \(result))")
            return
        }
        expect(!name.isEmpty, "the fusion produced a form (\(name))")
        expect(fusing.collection.count == before, "the fused partner replaced the one spent")
        expect(
            !fusing.collection.contains { $0.id == graduated.id },
            "the partner that was spent is gone"
        )
        expect(fusing.friends.count == 1, "the visiting tamer's card is not consumed")
        expect(fusing.wallet.dna.stock == 0, "the fusion spent the charge")
        expect(
            fusing.seenDigimon.count > 1,
            "the fused form is recorded in the DigiDex"
        )

        // Determinism, for the same reason digivolution is: re-importing a card
        // must not become a way to reroll a form the tamer did not like.
        guard let replay = makeStore(collection: [graduated]),
              case .fused(let again) = replay.jogress(graduated, with: friend)
        else {
            expect(false, "the replay fused at all")
            return
        }
        expect(again == name, "the same pair always fuses into the same form")

        // A canary for the ordering, not merely for the value. The fusion pool
        // is built from a Set intersection, and Swift seeds its hasher per
        // process — so before that pool was sorted, this pair produced a
        // different form on most launches. A single process cannot observe that
        // variance, but a pinned outcome catches its return: with the sort gone
        // this fails on four runs in five.
        //
        // Regenerating digidex.bin can legitimately move this. If it does, check
        // that fusions are still stable across launches before updating it.
        expect(
            name == "Shoutmon X7(Superior Mode)",
            "the fusion is pinned across launches, not just within one (got \(name))"
        )
    }

    /// Mirror of the codec's private decoder, so the test can look inside a card
    /// rather than trusting the encoder to describe itself.
    static func decodeBase64url(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    /// Rarity is a description of the evolution graph, not a balance knob, so
    /// what is pinned here is that it keeps describing the graph.
    /// The stars are a second reading of the route count, so what has to be
    /// pinned is that they cannot say anything the count does not.
    static func testRarityStars() {
        expect(DigiRarity(routes: 12).stars == 1, "a common form is one star")
        expect(DigiRarity(routes: 4).stars == 2, "an uncommon form is two")
        expect(DigiRarity(routes: 1).stars == 3, "a rare form is three")
        expect(
            DigiRarity(routes: 0).stars == nil,
            "a form nothing routes into is off the scale, not at the top of it"
        )

        // Monotonic and bounded across the whole range the graph produces. A
        // scale that crossed over somewhere would be worse than no scale.
        var previous = DigiRarity.starScale + 1
        var monotonic = true
        var onScale = true
        for routes in 0...200 {
            guard let stars = DigiRarity(routes: routes).stars else { continue }
            if stars > previous { monotonic = false }
            if !(1...DigiRarity.starScale).contains(stars) { onScale = false }
            previous = stars
        }
        expect(monotonic, "stars never rise as the route count rises")
        expect(onScale, "every form lands on the \(DigiRarity.starScale)-star scale or off it")

        // The X-Antibody question, answered from the shipped index rather than
        // from intuition: an X form is *not* harder to route to. Its median is
        // above the roster's, and a larger share of X forms are Common. So the
        // stars must not treat X as a tier — what makes one rare is the roll at
        // the digivolution, which is a different axis and is stated separately.
        let dex = DigiDex.shared
        func median(_ entries: [DigimonEntry]) -> Int {
            let routes = entries.map { dex.routesInto($0.id) }.sorted()
            return routes.isEmpty ? 0 : routes[routes.count / 2]
        }
        let xForms = dex.all.filter(\.x)
        expect(xForms.count > 100, "the index carries X forms to reason about (\(xForms.count))")
        expect(
            median(xForms) >= median(dex.all),
            "X forms are not rarer on the graph (median \(median(xForms)) against \(median(dex.all)))"
        )
        let xCommon = xForms.filter { DigiRarity(routes: dex.routesInto($0.id)) == .common }.count
        let allCommon = dex.all.filter { DigiRarity(routes: dex.routesInto($0.id)) == .common }.count
        expect(
            Double(xCommon) / Double(xForms.count) > Double(allCommon) / Double(dex.all.count),
            "more of the X roster is Common than of the roster at large "
                + "(\(xCommon * 100 / xForms.count)% against \(allCommon * 100 / dex.all.count)%)"
        )

        // And the axis that does make it rare, so the card's claim has a number
        // behind it like every other claim in the app.
        var disciplined = CareProfile()
        disciplined.discipline = 100
        let best = CareEngine.xAntibodyChance(profile: disciplined, hasCharm: false)
        expect(best < 0.05, "even a perfect streak leaves the X roll rare (\(String(format: "%.1f%%", best * 100)))")
        expect(
            best > CareEngine.xAntibodyChance(profile: CareProfile(), hasCharm: false),
            "discipline is what improves the roll"
        )
    }

    /// The local Jogress — two of the tamer's own graduated partners.
    ///
    /// It had no caller until the collection got a screen, so what is pinned
    /// here is mostly the guarding: every way it can refuse has to leave the
    /// collection exactly as it was. A fusion that half-happened would eat weeks
    /// of someone's raising.
    @MainActor
    static func testCollection() {
        guard let sample = DigiDex.shared.entries(stage: .ultimate).first,
              let other = DigiDex.shared.entries(stage: .ultimate).dropFirst().first
        else {
            expect(false, "the dex has two Ultimates to fuse")
            return
        }

        func partner(seed: UInt64, id: Int) -> Partner {
            var partner = Partner(seed: seed)
            partner.digimonID = id
            partner.stage = .ultimate
            partner.lineage = [id]
            partner.tokens = 8_000_000
            partner.retiredAt = Date()
            return partner
        }

        let left = partner(seed: 111, id: sample.id)
        let right = partner(seed: 222, id: other.id)

        func makeStore(_ collection: [Partner], charges: Int = 1) -> PartnerStore? {
            let url = URL(fileURLWithPath: NSTemporaryDirectory() + "digitest-coll-\(UUID()).json")
            var wallet = Wallet()
            wallet.dna.stock = charges
            var current = Partner(seed: 9_001)
            current.digimonID = sample.id
            current.stage = .adult
            let file = PartnerStore.SaveFile(
                partner: current, collection: collection, seenDigimon: [sample.id],
                seenXAntibody: [], baseline: 0, hasBaseline: true, profile: nil, wallet: wallet
            )
            guard let data = try? JSONEncoder().encode(file),
                  (try? data.write(to: url, options: .atomic)) != nil
            else { return nil }
            return PartnerStore(storeURL: url)
        }

        guard let store = makeStore([left, right]) else {
            expect(false, "a store with a collection can be built")
            return
        }

        // Every refusal, and each one has to consume nothing.
        expect(store.jogress(left, left) == .samePartner, "a partner cannot fuse with itself")
        expect(
            store.jogress(left, partner(seed: 333, id: other.id)) == .notInCollection,
            "a partner outside the collection cannot be fused"
        )
        expect(store.collection.count == 2, "a refused fusion consumed nothing")
        expect(store.wallet.dna.stock == 1, "a refused fusion spent no charge")

        guard let broke = makeStore([left, right], charges: 0) else {
            expect(false, "a store with no charges can be built")
            return
        }
        expect(broke.jogress(left, right) == .noCharge, "a local Jogress costs a DNA Charge")
        expect(broke.collection.count == 2, "the empty meter cost nothing else")

        // The real path.
        let before = store.seenDigimon.count
        guard case .fused(let name) = store.jogress(left, right) else {
            expect(false, "two graduated partners fuse")
            return
        }
        expect(!name.isEmpty, "the fusion produced a form (\(name))")
        expect(store.collection.count == 1, "both halves were spent and one form took their place")
        expect(
            !store.collection.contains { $0.id == left.id || $0.id == right.id },
            "neither half is still in the collection"
        )
        expect(store.wallet.dna.stock == 0, "the fusion spent the charge")
        expect(store.seenDigimon.count > before, "the fused form is recorded in the DigiDex")
        expect(
            store.collection.first?.lineage.count == left.lineage.count + right.lineage.count + 1,
            "the fused partner carries both lineages"
        )

        // Determinism, for the same reason every other roll here is deterministic.
        guard let replay = makeStore([left, right]),
              case .fused(let again) = replay.jogress(left, right)
        else {
            expect(false, "the replay fused at all")
            return
        }
        expect(again == name, "the same pair always fuses into the same form")
    }

    static func testDexDetail() {
        let dex = DigiDex.shared

        // The reverse index rebuilt at load has to match a direct count over
        // `next`, because the `prior` edges it replaces were dropped from the
        // shipped file.
        var expected: [Int: Int] = [:]
        for entry in dex.all {
            for target in entry.next { expected[target, default: 0] += 1 }
        }
        let mismatches = dex.all.filter { dex.routesInto($0.id) != (expected[$0.id] ?? 0) }
        expect(mismatches.isEmpty, "the reverse index matches the forward edges")

        expect(DigiRarity(routes: 0) == .unreachable, "no route in reads as unreachable")
        expect(DigiRarity(routes: 1) == .rare, "a single route reads as rare")
        expect(DigiRarity(routes: 2) == .rare, "two routes still read as rare")
        expect(DigiRarity(routes: 3) == .uncommon, "three routes read as uncommon")
        expect(DigiRarity(routes: 7) == .common, "the median form reads as common")

        // The tiers have to actually split the roster; a scheme that files
        // everything under one label describes nothing.
        var buckets: [String: Int] = [:]
        for entry in dex.all {
            buckets[dex.rarity(of: entry).label, default: 0] += 1
        }
        expect(buckets.count == 4, "every tier is populated (\(buckets))")
        let biggest = buckets.values.max() ?? 0
        expect(
            biggest < dex.all.count * 3 / 4,
            "no single tier swallows the roster (largest \(biggest)/\(dex.all.count))"
        )

        // A form with no route in must really have none, or the label lies.
        if let orphan = dex.all.first(where: { dex.rarity(of: $0) == .unreachable }) {
            expect(
                !dex.all.contains { $0.next.contains(orphan.id) },
                "\(orphan.name) is labelled unreachable and nothing digivolves into it"
            )
        }

        // MARK: The reference-book payload

        let payload = """
        {"id":1,"releaseDate":"1997",
         "descriptions":[
           {"language":"jap","description":"日本語"},
           {"language":"en_us","description":"A Reptile Digimon."}],
         "skills":[
           {"skill":"Baby Flame","translation":"Pepper Breath"},
           {"skill":"Sharp Claws","translation":""},
           {"skill":"","translation":"ignored"}]}
        """
        guard let detail = DetailLoader.parse(Data(payload.utf8), id: 1) else {
            expect(false, "a digi-api payload parses")
            return
        }
        expect(detail.summary == "A Reptile Digimon.", "the English entry is the one taken")
        expect(detail.year == "1997", "the release year is kept")
        expect(detail.skills.count == 2, "a nameless skill is dropped (\(detail.skills.count))")
        expect(
            detail.skills.first?.translation == "Pepper Breath",
            "a skill keeps its English gloss"
        )
        expect(
            detail.skills.last?.translation == nil,
            "an empty gloss becomes no gloss rather than an empty line"
        )

        // Some entries carry the year as a number instead of a string.
        let numeric = #"{"id":2,"releaseDate":1999,"descriptions":[],"skills":[]}"#
        expect(
            DetailLoader.parse(Data(numeric.utf8), id: 2)?.year == "1999",
            "a numeric release year is read too"
        )

        // Nothing worth showing must not be cached as an empty card.
        let barren = #"{"id":3,"descriptions":[],"skills":[]}"#
        expect(
            DetailLoader.parse(Data(barren.utf8), id: 3) == nil,
            "an entry with nothing in it is not cached as a blank card"
        )
        expect(
            DetailLoader.parse(Data("not json".utf8), id: 4) == nil,
            "a malformed payload is refused"
        )

        // A card written by an older build must still decode, like every other
        // persisted type here.
        let legacy = #"{"id":9}"#
        let old = try? JSONDecoder().decode(DigimonDetail.self, from: Data(legacy.utf8))
        expect(old?.id == 9, "a detail cached before the newer fields still decodes")
        expect(old?.skills.isEmpty == true, "a missing skill list defaults cleanly")

        // The silhouette has to keep the cut-out's shape, or it is a grey box.
        let source = NSImage(size: NSSize(width: 40, height: 40))
        source.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8, y: 8, width: 24, height: 24)).fill()
        source.unlockFocus()
        let flat = SpriteLoader.flatten(source)
        expect(flat.size == source.size, "flattening does not resize the sprite")
        if let a = SelfTest.PixelSampler(source), let b = SelfTest.PixelSampler(flat) {
            expect(
                a.alpha(atFraction: 0.05, 0.05) < 16 && b.alpha(atFraction: 0.05, 0.05) < 16,
                "the transparent corner stays transparent"
            )
            expect(
                a.alpha(atFraction: 0.5, 0.5) > 200 && b.alpha(atFraction: 0.5, 0.5) > 200,
                "the filled centre stays filled"
            )
            // The point of a silhouette is that it withholds everything except
            // the shape. A translucent fill left more than half the artwork
            // showing through, so the whole roster of "one step away" forms was
            // legible in colour on the DigiDex — which is the spoiler the three
            // states exist to avoid.
            let (red, green, blue, _) = b.rgba(atFraction: 0.5, 0.5)
            expect(
                abs(red - green) < 6 && abs(green - blue) < 6,
                "the silhouette keeps no colour from the artwork (\(red),\(green),\(blue))"
            )
            let original = a.rgba(atFraction: 0.5, 0.5)
            expect(
                abs(red - original.0) > 40,
                "the silhouette does not read as the original (\(red) vs \(original.0))"
            )
        } else {
            expect(false, "the flattened sprite is readable")
        }
    }

    static func testRealLogs() async {
        var found = false
        var allEvents: [UsageEvent] = []

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
            allEvents.append(contentsOf: events)

            let usage = UsageAggregator.summarize(provider: provider.id, events: events)
            print("""
                  \(provider.id.displayName): \(events.count) events, \
                  \(TokenFormatter.short(usage.allTime.billable)) billable, \
                  \(TokenFormatter.short(usage.allTime.total)) total, \
                  \(usage.sessionCount) sessions, \(usage.activeDays.count) active days \
                  (\(String(format: "%.2f", elapsed))s)
                  """)
            if !usage.projects.isEmpty {
                let top = usage.projects.prefix(5).map {
                    "\($0.name) \(TokenFormatter.short($0.counts.billable))"
                }
                print("    top projects: \(top.joined(separator: ", "))")
            }
            expect(usage.allTime.billable > 0, "\(provider.id.displayName): billable tokens found")
            expect(
                !usage.projects.isEmpty,
                "\(provider.id.displayName): the breakdown found projects (\(usage.projects.count))"
            )
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
            return
        }

        // What the coach actually says about this machine. Calibration is only
        // meaningful against the profile the app really computes here, so the
        // figures are printed and the claims are checked for consistency with
        // them rather than against a fixture that can drift away from reality.
        let report = Coach.report(events: allEvents)
        print("""
              Coach: \(report.sessions) sessions, \
              \(TokenFormatter.short(report.billable)) billable, \
              \(Int(report.cacheShare * 100))% cache share, \
              \(String(format: "%.1f", report.amortisation))x amortisation, \
              median session \(TokenFormatter.short(report.medianSession))
              """)
        for item in report.advice {
            print("    · \(item.title) — \(item.evidence)")
        }
        if report.advice.isEmpty, !report.isTooEarly {
            print("    · nothing to flag")
        }

        expect(
            report.billable > 0 && report.sessions > 0,
            "Coach: the real profile has a basis to reason from"
        )
        // Each rule is allowed to fire, but only in agreement with the figure
        // printed above — a rule that fires against its own evidence is a bug.
        expect(
            report.advice.contains { $0.id == "cache-reuse" } == (report.cacheShare < Coach.cacheShareFloor),
            "Coach: the cache verdict on this machine matches its own measurement"
        )
        expect(
            report.advice.filter { $0.id == "session-length" }.isEmpty
                || report.medianSession < Coach.shortSessionBar,
            "Coach: session advice on this machine matches its own measurement"
        )
        expect(
            Set(report.advice.map(\.id)).count == report.advice.count,
            "Coach: no rule fires twice"
        )
    }
}
