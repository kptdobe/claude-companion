import Foundation

/// PaperclipAI runs Claude via the Agent SDK (`sdk-cli`), but for the user each
/// session lives in a browser tab at `localhost:3100/<project>/issues/<key>`,
/// not in Claude Desktop. These helpers recover the issue a session is working
/// on so the companion can focus the right tab.
enum Paperclip {
    /// Base URL of the local PaperclipAI instance.
    static let baseURL = "http://localhost:3100"

    /// The most recent issue key referenced in a Paperclip "wake payload"
    /// transcript. Each heartbeat carries a `- issue: <KEY> …` line scoped to
    /// the issue being worked on; the last one is the current issue.
    /// Returns nil for non-Paperclip transcripts (the detection signal).
    static func issueKey(fromTranscript text: String) -> String? {
        let pattern = #"-\s*issue:\s*([A-Z][A-Z0-9]*-[0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last else { return nil }
        return ns.substring(with: last.range(at: 1))
    }

    /// `http://localhost:3100/COR/issues/COR-95` for key `COR-95`.
    static func issueURL(forKey key: String, baseURL: String = Paperclip.baseURL) -> URL? {
        guard let prefix = key.split(separator: "-").first, !prefix.isEmpty else { return nil }
        return URL(string: "\(baseURL)/\(prefix)/issues/\(key)")
    }
}
