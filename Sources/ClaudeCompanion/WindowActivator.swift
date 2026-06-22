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
        case .sdk, .unknown:
            // Headless or unknown — nothing focusable; just surface Claude.app.
            activateApp(named: "Claude")
        }
    }

    // MARK: - VS Code

    private static func activateVSCode(for session: Session, ideLocks: [IDELock]) {
        // The window title contains the workspace folder's basename.
        let folder = bestWorkspace(for: session.cwd, in: ideLocks) ?? session.cwd
        let name = (folder as NSString).lastPathComponent
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Visual Studio Code" to activate
        tell application "System Events"
            tell process "Code"
                set frontmost to true
                repeat with w in windows
                    if name of w contains "\(escaped)" then
                        perform action "AXRaise" of w
                        exit repeat
                    end if
                end repeat
            end tell
        end tell
        """
        run(script)
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
