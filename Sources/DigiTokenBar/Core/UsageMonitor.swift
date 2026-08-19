import Foundation

/// Drives refreshes and keeps the latest snapshot for the UI.
@MainActor
final class UsageMonitor {
    private(set) var snapshot = UsageSnapshot()
    private(set) var events: [UsageEvent] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    private(set) var lastError: String?

    /// Fired after every completed refresh so the UI can redraw.
    var onChange: (() -> Void)?

    var refreshInterval: TimeInterval = 120 {
        didSet { restartTimer() }
    }

    private let providers: [any UsageProvider]
    /// One cache per provider, so a provider's archive totals are its own and
    /// nothing has to filter a shared file by path prefix.
    private let caches: [ProviderID: ScanCache]
    private var timer: Timer?
    private weak var partnerStore: PartnerStore?

    init(providers: [any UsageProvider] = [ClaudeCodeProvider(), CodexProvider()]) {
        self.providers = providers
        caches = Dictionary(
            uniqueKeysWithValues: providers.map { ($0.id, ScanCache(url: Self.cacheURL(for: $0.id))) }
        )
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DigiTokenBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func cacheURL(for provider: ProviderID) -> URL {
        supportDirectory.appendingPathComponent("scan-\(provider.rawValue).json")
    }

    func attach(partnerStore: PartnerStore) {
        self.partnerStore = partnerStore
    }

    func start() {
        Task { await refresh() }
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        guard refreshInterval > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let providers = self.providers
        let caches = self.caches

        // Log trees get large; scanning them on the main actor would stutter the
        // popover animation every refresh.
        let result: (UsageSnapshot, [UsageEvent]) = await Task.detached(priority: .utility) {
            var snapshot = UsageSnapshot()
            var all: [UsageEvent] = []

            for provider in providers where provider.isAvailable() {
                guard let cache = caches[provider.id] else { continue }
                let events = provider.scan(cache: cache)
                cache.forgetMissingFiles()
                let archive = cache.archive
                guard !events.isEmpty || archive.eventCount > 0 else { continue }
                snapshot.providers[provider.id] = UsageAggregator.summarize(
                    provider: provider.id, events: events, archive: archive
                )
                all.append(contentsOf: events)
                cache.persist()
            }
            return (snapshot, all)
        }.value

        snapshot = result.0
        events = result.1
        lastRefresh = Date()
        lastError = snapshot.providers.isEmpty
            ? "No supported AI coding tool found on this machine."
            : nil

        partnerStore?.apply(snapshot: snapshot, events: events)
        onChange?()
    }
}
