import Foundation

/// Where a Claude Code session is running. Mirrors the `entrypoint` field
/// found in `~/.claude/sessions/<pid>.json`.
enum Entrypoint: String, Codable, CaseIterable {
    case cli
    case vscode = "claude-vscode"
    case desktop = "claude-desktop"
    case sdk = "sdk-cli"
    case unknown

    init(raw: String?) {
        self = Entrypoint(rawValue: raw ?? "") ?? .unknown
    }

    /// Human label for the popover.
    var label: String {
        switch self {
        case .cli: return "Terminal"
        case .vscode: return "VS Code"
        case .desktop: return "Claude Desktop"
        case .sdk: return "SDK / headless"
        case .unknown: return "Unknown"
        }
    }
}

/// What a session is doing right now, as far as the companion can tell.
enum SessionActivity: String, Codable {
    /// Claude is actively working (generating, running tools).
    case thinking
    /// Claude needs you — a permission prompt or an idle notification.
    case waiting
    /// Claude finished its turn and is awaiting your next prompt.
    case idle
    /// No state information yet.
    case unknown

    /// Ordering for the popover: things needing attention float to the top.
    var sortRank: Int {
        switch self {
        case .waiting: return 0
        case .thinking: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }

    /// Tools that block waiting for the user's response. A `PreToolUse` for one
    /// of these means Claude is now waiting on you, not working.
    /// Kept in sync with the `BLOCKING_TOOLS` set in `claude-companion-hook`.
    static let blockingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Tool-aware mapping. A `PreToolUse` for a blocking tool is `.waiting`;
    /// otherwise this defers to the event-only mapping.
    static func from(hookEvent: String, toolName: String?) -> SessionActivity {
        if hookEvent == "PreToolUse", let tool = toolName, blockingTools.contains(tool) {
            return .waiting
        }
        return from(hookEvent: hookEvent)
    }

    /// Maps a Claude Code hook event name to the activity it implies.
    /// Kept in sync with the installer's event→state map (`install-hooks.mjs`).
    static func from(hookEvent: String) -> SessionActivity {
        switch hookEvent {
        // Actively working. A subagent stopping does NOT end the main turn,
        // so the main loop keeps thinking.
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact", "SubagentStop":
            return .thinking
        // Needs you: a permission/idle notification, OR the turn just ended —
        // in Claude Code, `Stop` is precisely when it's your move again.
        case "Notification", "Stop":
            return .waiting
        // The whole session has closed.
        case "SessionEnd":
            return .idle
        default:
            return .unknown
        }
    }
}

/// Decoded `~/.claude/sessions/<pid>.json`.
struct SessionRecord: Codable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: Double?
    let version: String?
    let kind: String?
    let entrypoint: String?

    static func decode(_ data: Data) -> SessionRecord? {
        try? JSONDecoder().decode(SessionRecord.self, from: data)
    }
}

/// Decoded `~/.claude/companion-state/<sessionId>.json`, written by the hook.
struct StateRecord: Codable {
    let sessionId: String
    let state: String
    let event: String?
    let cwd: String?
    /// Epoch seconds.
    let ts: Double?

    var activity: SessionActivity {
        SessionActivity(rawValue: state) ?? .unknown
    }

    static func decode(_ data: Data) -> StateRecord? {
        try? JSONDecoder().decode(StateRecord.self, from: data)
    }
}

/// Decoded `~/.claude/ide/<pid>.lock` — maps a workspace folder to an IDE.
struct IDELock: Codable {
    let pid: Int
    let workspaceFolders: [String]
    let ideName: String?

    static func decode(_ data: Data) -> IDELock? {
        try? JSONDecoder().decode(IDELock.self, from: data)
    }
}

/// A fully merged session ready to display.
struct Session: Identifiable, Equatable {
    let id: String          // sessionId
    let pid: Int
    let cwd: String
    let entrypoint: Entrypoint
    var activity: SessionActivity
    var lastActivity: Date
    /// Title from the transcript (custom or AI), if resolved.
    var customTitle: String?

    /// A human label: prefer the transcript title, else the directory name.
    var title: String {
        if let custom = customTitle, !custom.isEmpty { return custom }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id && lhs.activity == rhs.activity &&
        lhs.pid == rhs.pid && lhs.cwd == rhs.cwd
    }
}
