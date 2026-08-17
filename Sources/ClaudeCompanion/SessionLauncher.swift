import AppKit

/// Reopens a closed session by resuming its Claude Code transcript in a new
/// Terminal window. Resuming requires the original working directory, so we
/// `cd` there first; when headroom is installed we launch through it
/// (`headroom wrap claude …`) so the resumed session keeps context compression.
enum SessionLauncher {
    /// Reopen a pinned session (always in Terminal, per design).
    static func reopen(_ pinned: PinnedSession) {
        let command = resumeCommand(
            cwd: pinned.cwd,
            sessionId: pinned.sessionId,
            headroomPath: HeadroomStore.locate()?.path)
        run(terminalAppleScript(forCommand: command))
    }

    /// The shell command to resume a session. Through headroom when available,
    /// otherwise plain `claude`. Pure — unit-tested.
    static func resumeCommand(cwd: String, sessionId: String, headroomPath: String?) -> String {
        let dir = shellQuote(cwd)
        let id = sessionId
        if let headroom = headroomPath {
            return "cd \(dir) && \(shellQuote(headroom)) wrap claude --resume \(id)"
        }
        return "cd \(dir) && claude --resume \(id)"
    }

    /// Wrap a shell command in an AppleScript that opens a new Terminal window
    /// and runs it. Pure — unit-tested.
    static func terminalAppleScript(forCommand command: String) -> String {
        """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscape(command))"
        end tell
        """
    }

    // MARK: - Helpers

    /// POSIX single-quote escaping: wrap in single quotes, and close/escape/
    /// reopen around any embedded single quote (`'` → `'\''`).
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape a string for an AppleScript double-quoted literal (`\` then `"`).
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ script: String) {
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            NSLog("Claude Companion: failed to reopen session: %@", error)
        }
    }
}
