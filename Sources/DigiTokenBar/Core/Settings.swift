import AppKit
import Foundation
import ServiceManagement

/// User preferences, persisted straight to `UserDefaults`.
@MainActor
final class Settings {
    static let shared = Settings()

    var onChange: (() -> Void)?

    private enum Key {
        static let showTokens = "showTokensInMenuBar"
        static let animate = "animateSprite"
        static let floatingPet = "floatingPetEnabled"
        static let petSize = "floatingPetSize"
        static let petOrigin = "floatingPetOrigin"
        static let notifications = "notificationsEnabled"
        static let refreshMinutes = "refreshMinutes"
        static let growthPace = "growthPace"
    }

    /// How fast the ladder advances. Changing it re-evaluates the current
    /// partner immediately, which can grant several rungs at once when moving
    /// to a quicker pace — that is intended, not a glitch.
    var growthPace: GrowthPace {
        didSet { write(growthPace.rawValue, Key.growthPace) }
    }

    var showTokensInMenuBar: Bool { didSet { write(showTokensInMenuBar, Key.showTokens) } }
    var animateSprite: Bool { didSet { write(animateSprite, Key.animate) } }
    var floatingPetEnabled: Bool { didSet { write(floatingPetEnabled, Key.floatingPet) } }
    var notificationsEnabled: Bool { didSet { write(notificationsEnabled, Key.notifications) } }

    /// Clamped on the way in: a pet larger than a quarter of the screen stops
    /// being a pet and starts being a window.
    var petSize: Double {
        didSet {
            petSize = min(240, max(48, petSize))
            write(petSize, Key.petSize)
        }
    }

    var refreshMinutes: Int {
        didSet {
            refreshMinutes = min(60, max(1, refreshMinutes))
            write(refreshMinutes, Key.refreshMinutes)
        }
    }

    /// Where the tamer last dragged the floating pet.
    var petOrigin: CGPoint? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.petOrigin) else { return nil }
            return NSPointFromString(raw)
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: Key.petOrigin)
                return
            }
            UserDefaults.standard.set(NSStringFromPoint(newValue), forKey: Key.petOrigin)
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.showTokens: true,
            Key.animate: true,
            Key.floatingPet: false,
            Key.petSize: 96.0,
            Key.notifications: true,
            Key.refreshMinutes: 2,
            Key.growthPace: GrowthPace.standard.rawValue,
        ])
        growthPace = GrowthPace(rawValue: defaults.string(forKey: Key.growthPace) ?? "")
            ?? .standard
        showTokensInMenuBar = defaults.bool(forKey: Key.showTokens)
        animateSprite = defaults.bool(forKey: Key.animate)
        floatingPetEnabled = defaults.bool(forKey: Key.floatingPet)
        notificationsEnabled = defaults.bool(forKey: Key.notifications)
        petSize = defaults.double(forKey: Key.petSize)
        refreshMinutes = defaults.integer(forKey: Key.refreshMinutes)
    }

    private func write(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }

    // MARK: - Launch at login

    /// Whether macOS starts the app at login. Reads live rather than caching,
    /// because the user can also flip it in System Settings.
    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the error when the request fails, so the caller can say why
    /// instead of silently leaving the checkbox in the wrong state.
    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> Error? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            onChange?()
            return nil
        } catch {
            return error
        }
    }
}
