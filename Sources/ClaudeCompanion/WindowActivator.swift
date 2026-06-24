import AppKit
import Foundation

/// Brings the window hosting a given session to the foreground.
///
/// Strategy depends on the entrypoint:
/// - `.desktop`  → activate Claude.app
/// - `.vscode`   → activate VS Code and raise the window whose title matches the workspace
/// - `.cli`      → resolve the session's controlling TTY and select the matching terminal tab
enum WindowActivator {

    static func activate(_ session: Session,
                         ideLocks: [IDELock] = WindowActivator.readIDELocks()) {
        switch session.entrypoint {
        case .desktop:
            activateApp(named: "Claude")
        case .vscode:
            activateVSCode(for: session, ideLocks: ideLocks)
        case .cli:
            activateTerminal(for: session)
        case .sdk:
            activateSDK(for: session)
        case .unknown:
            // Nothing focusable — surface Claude.app.
            activateApp(named: "Claude")
        }
    }

    // MARK: - SDK / PaperclipAI (browser)

    /// An `sdk-cli` session driven by PaperclipAI lives in a browser tab. Find
    /// its issue from the transcript and focus the matching Chrome tab; fall
    /// back to Claude.app if it's not a Paperclip session.
    private static func activateSDK(for session: Session) {
        let store = TranscriptTitleStore()
        guard let key = store.paperclipIssueKey(for: session.id, cwd: session.cwd) else {
            activateApp(named: "Claude")
            return
        }
        jumpToPaperclipIssue(key: key)
    }

    /// Focus the Chrome tab for a Paperclip issue key.
    private static func jumpToPaperclipIssue(key: String) {
        guard let url = Paperclip.issueURL(forKey: key) else { return }
        focusChromeTab(matching: "/issues/\(key)", fallbackURL: url)
    }

    /// Focus the Chrome tab whose URL contains `needle`; open `fallbackURL` if
    /// it isn't open. Chrome ignores `set active tab index` *visually* on recent
    /// macOS, so we switch tabs with the ⌘-number keyboard shortcut instead.
    private static func focusChromeTab(matching needle: String, fallbackURL: URL) {
        let chromeRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == "com.google.Chrome" }
        guard chromeRunning else {
            NSWorkspace.shared.open(fallbackURL)
            return
        }
        let needleEsc = needle.replacingOccurrences(of: "\"", with: "")
        // Locate the tab + raise its window. Returns "<tabIndex> <tabCount>"
        // (tabIndex 0 = not found).
        let find = """
        tell application "Google Chrome"
            set mWin to 0
            set mTab to 0
            set tc to 0
            repeat with wi from 1 to (count of windows)
                set w to window wi
                set n to (count of tabs of w)
                repeat with ti from 1 to n
                    if (URL of tab ti of w) contains "\(needleEsc)" then
                        set mWin to wi
                        set mTab to ti
                        set tc to n
                        exit repeat
                    end if
                end repeat
                if mTab > 0 then exit repeat
            end repeat
            if mWin > 0 then set index of window mWin to 1
            return (mTab as text) & " " & (tc as text)
        end tell
        """
        let (out, _, _) = runAppleScript(find)
        let nums = (out ?? "").split(separator: " ").compactMap { Int($0) }
        let tabIndex = nums.first ?? 0
        let tabCount = nums.count > 1 ? nums[1] : 0

        guard tabIndex > 0 else {            // not open → open it in a new tab
            NSWorkspace.shared.open(fallbackURL)
            return
        }

        // ⌘1–⌘8 select tabs 1–8; ⌘9 selects the LAST tab.
        let digit: Int? = tabIndex <= 8 ? tabIndex : (tabIndex == tabCount ? 9 : nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            _ = shell("/usr/bin/open", ["-a", "Google Chrome"])
            guard let digit else { return }
            // After Chrome is frontmost, post the ⌘-number shortcut natively.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                pressCommandDigit(digit)
            }
        }
    }

    /// Post ⌘+<digit> to the frontmost app via CGEvent (needs Accessibility,
    /// which the app already has). This actually switches the visible tab.
    private static func pressCommandDigit(_ digit: Int) {
        // US keyboard virtual keycodes for the number row.
        let keycodes: [Int: CGKeyCode] = [1: 18, 2: 19, 3: 20, 4: 21, 5: 23,
                                          6: 22, 7: 26, 8: 28, 9: 25]
        guard let key = keycodes[digit] else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Run AppleScript, capturing stdout, stderr, and exit status.
    private static func runAppleScript(_ script: String) -> (out: String?, err: String?, status: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
            let o = outPipe.fileHandleForReading.readDataToEndOfFile()
            let e = errPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (String(data: o, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    String(data: e, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    task.terminationStatus)
        } catch {
            return (nil, "\(error)", -1)
        }
    }

    // MARK: - VS Code

    /// Known VS Code family bundle identifiers, in preference order.
    private static let vscodeBundleIDs = [
        "com.microsoft.VSCode",          // VS Code
        "com.microsoft.VSCodeInsiders",  // Insiders
        "com.visualstudio.code.oss",     // Code - OSS
        "com.vscodium",                  // VSCodium
    ]

    private static func activateVSCode(for session: Session, ideLocks: [IDELock]) {
        // Prefer the IDE workspace that actually contains the session's cwd, so
        // we raise the window for *this* project, not a sibling.
        let folder = bestWorkspace(for: session.cwd, in: ideLocks) ?? session.cwd

        guard let app = WindowFocuser.runningApp(bundleIDs: vscodeBundleIDs) else {
            run("tell application \"Visual Studio Code\" to activate")
            return
        }

        let raised = WindowFocuser.focus(app: app, workspaceFolder: folder)
        // If we couldn't raise the right window only because we lack Accessibility
        // permission, prompt for it once (the app is already frontmost regardless).
        if !raised && !WindowFocuser.isTrusted {
            WindowFocuser.promptForAccessibilityOnce()
        }
    }

    /// Pick the IDE workspace that best contains the session cwd.
    static func bestWorkspace(for cwd: String, in locks: [IDELock]) -> String? {
        var best: String?
        for lock in locks {
            for folder in lock.workspaceFolders {
                if cwd == folder || cwd.hasPrefix(folder + "/") {
                    if best == nil || folder.count > best!.count { best = folder }
                }
            }
        }
        return best
    }

    // MARK: - Terminal

    private static func activateTerminal(for session: Session) {
        guard let tty = controllingTTY(of: session.pid) else {
            activateApp(named: "Terminal")
            return
        }
        // Try Terminal.app, then iTerm2. Each script is a no-op if the tty isn't theirs.
        run(terminalAppScript(tty: tty))
        run(iTermScript(tty: tty))
    }

    private static func terminalAppScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }

    private static func iTermScript(tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            tell t to select
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    /// `/dev/ttysXYZ` controlling terminal of a pid, or nil.
    static func controllingTTY(of pid: Int) -> String? {
        let out = shell("/bin/ps", ["-o", "tty=", "-p", String(pid)])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let out, !out.isEmpty, out != "??", out != "?" else { return nil }
        return out.hasPrefix("/dev/") ? out : "/dev/" + out
    }

    // MARK: - Helpers

    static func readIDELocks(
        dir: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ide")
    ) -> [IDELock] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return names
            .filter { $0.pathExtension == "lock" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap(IDELock.decode)
    }

    private static func activateApp(named name: String) {
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: { $0.localizedName == name }) {
            app.activate(options: [.activateAllWindows])
        } else {
            run("tell application \"\(name)\" to activate")
        }
    }

    @discardableResult
    private static func run(_ appleScript: String) -> String? {
        shell("/usr/bin/osascript", ["-e", appleScript])
    }

    @discardableResult
    private static func shell(_ launchPath: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
