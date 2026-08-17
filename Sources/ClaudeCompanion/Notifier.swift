import AppKit
import UserNotifications

/// Posts macOS user notifications when sessions change state.
///
/// UserNotifications requires a bundled, signed app (a bare `swift run` has no
/// bundle identifier). When unbundled we no-op rather than crash, so dev runs
/// still work — the shipped `ClaudeCompanion.app` gets real notifications.
final class Notifier {
    private let enabled: Bool
    private var authorized = false

    init() {
        enabled = Bundle.main.bundleIdentifier != nil
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    /// Post a notification. `sound` is used for attention-worthy transitions.
    func post(title: String, body: String, sound: Bool) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
