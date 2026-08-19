import AppKit
import UserNotifications

/// Posts a system notification when the partner reaches a milestone.
///
/// Digivolution is the payoff of the whole app and it happens while the popover
/// is closed, so without this the tamer only ever finds out later. Failures are
/// swallowed on purpose: an ad-hoc signed build may not be able to register with
/// the notification centre at all, and the in-app banner still covers that case.
@MainActor
enum Notifier {
    private static var authorized = false
    private static var askedOnce = false

    /// Whether the process can talk to the notification centre. A binary run
    /// straight from `.build` rather than from inside a bundle cannot, and
    /// calling `UNUserNotificationCenter.current()` there traps.
    private static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    static func requestAuthorizationIfNeeded() {
        guard isAvailable, !askedOnce, Settings.shared.notificationsEnabled else { return }
        askedOnce = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in authorized = granted }
        }
    }

    static func hatched(_ entry: DigimonEntry) {
        post(
            title: "Your DigiTama hatched",
            body: "\(entry.name) — \(DigiStage.babyI.dubName). Keep working and it will digivolve."
        )
    }

    static func digivolved(_ event: DigivolutionEvent) {
        let headline = event.isXAntibody ? "X-Antibody digivolution!" : "Digivolution!"
        post(
            title: headline,
            body: "\(event.from) digivolved to \(event.to.name) — \(event.stage.dubName) (\(event.reason))."
        )
    }

    private static func post(title: String, body: String) {
        guard isAvailable, Settings.shared.notificationsEnabled, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
