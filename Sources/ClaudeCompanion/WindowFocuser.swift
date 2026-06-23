import AppKit
import ApplicationServices

/// Raises a specific window of an app using the Accessibility API.
///
/// `osascript`/System Events can't switch windows without "assistive access",
/// and shelling out is fragile. Doing it natively via `AXUIElement` lets us
/// enumerate an app's windows, score each title against the target workspace,
/// and raise the best match — so clicking a session lands on the *right*
/// window even when an app has several open.
enum WindowFocuser {

    /// Is this process trusted for the Accessibility API? Required to raise windows.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static var hasPrompted = false

    /// Show the system Accessibility prompt at most once per launch — so a
    /// not-yet-granted state doesn't pop the dialog on every click.
    static func promptForAccessibilityOnce() {
        guard !hasPrompted else { return }
        hasPrompted = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// How well a window title matches a workspace folder.
    /// `2` = the folder's name is an exact title segment (the reliable case),
    /// `1` = the name appears only as a substring, `0` = no match.
    static func matchScore(title: String, workspaceFolder: String) -> Int {
        let name = (workspaceFolder as NSString).lastPathComponent
        guard !name.isEmpty else { return 0 }
        // VS Code joins title parts with an em dash: "file — rootName — …".
        let segments = title.components(separatedBy: "—")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if segments.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return 2
        }
        return title.range(of: name, options: .caseInsensitive) != nil ? 1 : 0
    }

    /// Bring `app` forward and raise the window best matching `workspaceFolder`.
    /// - Returns: true if a matching window was raised. (Activation still happens
    ///   even when false, so the app at least comes to the front.)
    @discardableResult
    static func focus(app: NSRunningApplication, workspaceFolder: String) -> Bool {
        app.activate(options: [.activateAllWindows])
        guard isTrusted else { return false }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return false }

        var best: (window: AXUIElement, score: Int)?
        for window in windows {
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let title = (titleValue as? String) ?? ""
            let score = matchScore(title: title, workspaceFolder: workspaceFolder)
            if score > (best?.score ?? 0) { best = (window, score) }
        }
        guard let target = best, target.score > 0 else { return false }

        // Raise + make main, and ensure the app itself is frontmost.
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(target.window, kAXRaiseAction as CFString)
        return true
    }

    /// First running app among the given bundle identifiers.
    static func runningApp(bundleIDs: [String]) -> NSRunningApplication? {
        for id in bundleIDs {
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: id).first {
                return app
            }
        }
        return nil
    }
}
