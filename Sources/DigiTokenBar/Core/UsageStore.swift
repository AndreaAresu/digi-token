import Foundation

/// Turns raw per-turn events into the rollups the UI and the partner read.
enum UsageAggregator {
    /// Length of the rolling rate-limit window both Claude and Codex meter on.
    static let blockDuration: TimeInterval = 5 * 3600

    /// Groups events into 5-hour blocks.
    ///
    /// A block opens at the top of the hour containing its first event, and
    /// closes when either the window elapses or the tamer goes quiet for a full
    /// window. The second rule is what makes an abandoned window detectable:
    /// without it a session resumed six hours later would silently extend the
    /// same block.
    static func blocks(from events: [UsageEvent], calendar: Calendar = .current) -> [UsageBlock] {
        guard !events.isEmpty else { return [] }
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var result: [UsageBlock] = []
        var current: UsageBlock?

        for event in sorted {
            if var block = current,
               event.timestamp < block.end,
               event.timestamp.timeIntervalSince(block.lastActivity) < blockDuration {
                block.counts += event.counts
                block.lastActivity = event.timestamp
                current = block
                continue
            }

            if let block = current { result.append(block) }
            let anchor = calendar.date(
                bySettingHour: calendar.component(.hour, from: event.timestamp),
                minute: 0, second: 0, of: event.timestamp
            ) ?? event.timestamp
            current = UsageBlock(
                start: anchor,
                end: anchor.addingTimeInterval(blockDuration),
                counts: event.counts,
                lastActivity: event.timestamp
            )
        }

        if let block = current { result.append(block) }
        return result
    }

    /// Rolls retained events up, folding in the archive for anything the cache
    /// has already aged out. All-time figures, active days and session counts
    /// span the archive too; today/week/month and blocks come from retained
    /// events alone, which is safe because retention outlasts a month.
    static func summarize(
        provider: ProviderID,
        events rawEvents: [UsageEvent],
        archive: UsageArchive = UsageArchive(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ProviderUsage {
        var usage = ProviderUsage(provider: provider)
        usage.allTime = archive.counts

        // The same assistant turn appears in every forked transcript that
        // contains it; count it once.
        var seen = Set<String>()
        let events = rawEvents.filter { seen.insert($0.dedupKey).inserted }
        guard !events.isEmpty else {
            usage.activeDays = archive.days.sorted(by: >)
            usage.sessionCount = archive.sessions.count
            return usage
        }

        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday

        var days = archive.days
        var sessions = archive.sessions
        var projectTotals = archive.projects
        var projectToday: [String: TokenCounts] = [:]
        var projectSeen: [String: Date] = [:]
        // Retained events only, so the busiest week is the busiest week the
        // cache still remembers one by one — the archive keeps totals, not
        // shapes. Retention outlasts a quarter, which is plenty of weeks.
        var perWeek: [Date: Int] = [:]

        for event in events {
            usage.allTime += event.counts
            days.insert(calendar.startOfDay(for: event.timestamp))
            sessions.insert(event.sessionID)

            if let project = event.project {
                projectTotals[project, default: TokenCounts()] += event.counts
                if event.timestamp >= startOfToday {
                    projectToday[project, default: TokenCounts()] += event.counts
                }
                if let seen = projectSeen[project] {
                    projectSeen[project] = max(seen, event.timestamp)
                } else {
                    projectSeen[project] = event.timestamp
                }
            }

            if event.timestamp >= startOfToday {
                usage.today += event.counts
                usage.todayCost += ModelPricing.cost(model: event.model, counts: event.counts)
            }
            if event.timestamp >= startOfWeek { usage.week += event.counts }
            if let week = calendar.dateInterval(of: .weekOfYear, for: event.timestamp)?.start {
                perWeek[week, default: 0] += event.counts.billable
            }
            if event.timestamp >= startOfMonth {
                usage.month += event.counts
                usage.monthCost += ModelPricing.cost(model: event.model, counts: event.counts)
            }
        }

        usage.sessionCount = sessions.count
        usage.activeDays = days.sorted(by: >)
        usage.lastActivity = events.map(\.timestamp).max()
        usage.projects = projectTotals
            .map { name, counts in
                ProjectUsage(
                    name: name,
                    counts: counts,
                    today: projectToday[name] ?? TokenCounts(),
                    lastActivity: projectSeen[name]
                )
            }
            .sorted { $0.counts.billable > $1.counts.billable }

        let allBlocks = blocks(from: events, calendar: calendar)
        usage.currentBlock = allBlocks.last.flatMap { $0.isActive ? $0 : nil }
        usage.recentBlocks = Array(allBlocks.suffix(24))

        // The only ceiling this app can honestly point at. Neither tool writes
        // its allowance in tokens, so "your busiest window so far" is offered
        // instead of a percentage of a limit nobody published: it is a thing
        // that actually happened, and it is labelled as such.
        usage.peakBlock = allBlocks.map(\.counts.billable).max() ?? 0
        usage.peakWeek = perWeek.values.max() ?? 0
        return usage
    }

    /// Consecutive days ending today or yesterday. Yesterday still counts so a
    /// streak does not die at midnight before the day has been worked.
    ///
    /// `frozenDays` are days a Streak Freeze covered. They count as worked here,
    /// but the UI always shows how many were frozen — softening a consequence is
    /// fine, hiding that it was softened is not.
    static func streak(
        activeDays: [Date],
        frozenDays: Set<Date> = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        var days = Set(activeDays.map { calendar.startOfDay(for: $0) })
        days.formUnion(frozenDays.map { calendar.startOfDay(for: $0) })
        let today = calendar.startOfDay(for: now)

        var cursor = today
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  days.contains(yesterday)
            else { return 0 }
            cursor = yesterday
        }

        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}
