import AppKit

/// Builds the shell command that resumes a closed session's Claude Code
/// transcript. Resuming requires the original working directory, so the command
/// `cd`s there first; when headroom is installed it runs through it
/// (`headroom wrap claude …`) so the resumed session keeps context compression.
enum SessionLauncher {
    /// Copy a pinned session's resume command to the clipboard so the user can
    /// paste it into any terminal.
    static func copyResumeCommand(_ pinned: PinnedSession) {
        let command = resumeCommand(
            cwd: pinned.cwd,
            sessionId: pinned.sessionId,
            headroomPath: HeadroomStore.locate()?.path)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    /// Environment the companion always sets for resumed sessions: tool search
    /// enabled and the API base pointed at the local proxy.
    static let resumeEnv = "ENABLE_TOOL_SEARCH=true ANTHROPIC_BASE_URL=http://localhost:8787"

    /// The shell command to resume a session. Through headroom when available,
    /// otherwise plain `claude`. Always exports `resumeEnv` first. Pure —
    /// unit-tested.
    static func resumeCommand(cwd: String, sessionId: String, headroomPath: String?) -> String {
        let dir = shellQuote(cwd)
        let id = sessionId
        if let headroom = headroomPath {
            return "cd \(dir) && \(resumeEnv) \(shellQuote(headroom)) wrap claude --resume \(id)"
        }
        return "cd \(dir) && \(resumeEnv) claude --resume \(id)"
    }

    // MARK: - Helpers

    /// POSIX single-quote escaping: wrap in single quotes, and close/escape/
    /// reopen around any embedded single quote (`'` → `'\''`).
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
