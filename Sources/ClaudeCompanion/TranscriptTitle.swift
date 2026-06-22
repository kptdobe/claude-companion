import Foundation

/// Pulls a human title out of a session's JSONL transcript.
///
/// Transcripts contain title lines such as:
///   {"type":"custom-title","customTitle":"macOS Claude companion app", ...}
///   {"type":"ai-title","aiTitle":"Build macOS Claude companion control center", ...}
/// A user-set custom title wins; otherwise the AI-generated title is used.
enum TranscriptTitle {
    /// Pure scan over transcript bytes — no I/O, so it's unit-testable.
    static func extract(fromTranscript data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var custom: String?
        var ai: String?
        text.enumerateLines { line, _ in
            // Cheap prefilter: both "custom-title" and "ai-title" contain "-title".
            guard line.contains("-title"),
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String else { return }
            if type == "custom-title", let value = obj["customTitle"] as? String {
                custom = value
            } else if type == "ai-title", let value = obj["aiTitle"] as? String {
                ai = value
            }
        }
        let title = (custom ?? ai)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false) ? title : nil
    }
}

/// Resolves and caches transcript titles by sessionId.
///
/// Titles rarely change, but transcripts grow constantly while a session is
/// thinking — so once a non-nil title is found it is cached for good, and files
/// are otherwise only re-scanned when their modification time changes.
final class TranscriptTitleStore {
    private let projectsDir: URL
    private var locationCache: [String: URL] = [:]
    private var titleCache: [String: (mtime: Date, title: String?)] = [:]

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")) {
        self.projectsDir = claudeDir.appendingPathComponent("projects")
    }

    func title(for sessionId: String, cwd: String) -> String? {
        // A found title never changes for our purposes — short-circuit.
        if let cached = titleCache[sessionId], cached.title != nil { return cached.title }

        guard let url = locate(sessionId: sessionId, cwd: cwd) else { return nil }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        if let cached = titleCache[sessionId], cached.mtime == mtime { return cached.title }

        let title = (try? Data(contentsOf: url)).flatMap(TranscriptTitle.extract)
        titleCache[sessionId] = (mtime, title)
        return title
    }

    /// Finds `<sessionId>.jsonl`: first via the encoded-cwd directory, then by
    /// scanning the project directories as a fallback.
    private func locate(sessionId: String, cwd: String) -> URL? {
        if let cached = locationCache[sessionId],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let file = sessionId + ".jsonl"
        let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let primary = projectsDir.appendingPathComponent(encoded).appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: primary.path) {
            locationCache[sessionId] = primary
            return primary
        }

        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) {
                locationCache[sessionId] = candidate
                return candidate
            }
        }
        return nil
    }
}
