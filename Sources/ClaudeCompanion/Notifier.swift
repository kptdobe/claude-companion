import AppKit

/// Posts macOS notifications when sessions change state.
///
/// Uses `NSUserNotificationCenter` rather than the modern `UserNotifications`
/// framework on purpose: `UNUserNotificationCenter` requires a stably-signed
/// bundle to get its authorization prompt, so on the ad-hoc-signed local build
/// the prompt never appears and every post is silently dropped. The older API
/// needs only a bundle identifier (which the `.app` has) — no prompt, no
/// entitlement, no stable signature — so notifications actually show. Deliver
/// still no-ops for a bare `swift run` (no bundle id), keeping dev runs quiet.
final class Notifier {
    private let enabled = Bundle.main.bundleIdentifier != nil

    /// Post a notification. `sound` is used for attention-worthy transitions.
    func post(title: String, body: String, sound: Bool) {
        guard enabled else { return }
        let note = NSUserNotification()
        note.title = title
        note.informativeText = body
        if sound { note.soundName = NSUserNotificationDefaultSoundName }
        let center = NSUserNotificationCenter.default
        // Show even if the companion happens to be the active app.
        center.delegate = Notifier.forcePresenter
        center.deliver(note)
    }

    /// Forces Notification Center to display our notifications even when the app
    /// is frontmost (default behaviour otherwise suppresses them).
    private static let forcePresenter = ForcePresenter()
    private final class ForcePresenter: NSObject, NSUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: NSUserNotificationCenter,
                                    shouldPresent notification: NSUserNotification) -> Bool {
            true
        }
    }
}
