import AppKit
import UserNotifications

/// Posts macOS notifications when sessions change state.
///
/// Uses the modern `UserNotifications` framework (`UNUserNotificationCenter`).
/// The legacy `NSUserNotification` API this used to rely on was deprecated in
/// macOS 11 and no longer delivers anything on macOS 15+/26 — `deliver` returns
/// without error but nothing ever appears, and the app never registers as a
/// notification client. `UNUserNotificationCenter` works for our signed,
/// bundled `LSUIElement` app because it has a stable bundle identifier and a
/// code signature (even ad-hoc): that's all the authorization prompt needs.
///
/// Delivery still no-ops for a bare `swift run` (no bundle id / no signature),
/// keeping dev runs quiet.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let enabled = Bundle.main.bundleIdentifier != nil
    private var authorized = false

    override init() {
        super.init()
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        // Present banners even when the companion is the frontmost app.
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
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
        // A nil trigger delivers immediately. A fresh UUID per post so rapid
        // transitions don't coalesce onto one another.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Show banners even when the app is frontmost (default would suppress them).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
