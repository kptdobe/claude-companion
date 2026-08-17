import Foundation

/// Aggregated token usage, ready for display.
struct UsageSnapshot: Equatable {
    /// Per-session lifetime totals, keyed by sessionId.
    var perSession: [String: UsageTotals] = [:]
    var today = UsageTotals()
    var last30 = UsageTotals()
    /// All-time totals across every transcript on disk.
    var lifetime = UsageTotals()
}

/// Scans `~/.claude/projects/**/*.jsonl` and tallies token usage + cost.
///
/// Transcripts are append-only, so this reads each file **incrementally**:
/// after the first pass it only parses bytes appended since the last scan,
/// which keeps the ~1.5s refresh cheap even while a session is streaming.
/// Not thread-safe — drive it from a single serial queue (see `SessionMonitor`).
final class UsageStore {
    private let projectsDir: URL

    /// Per-file parse cache. `offset` is how many bytes we've already consumed
    /// (always on a line boundary); `byDay` buckets by local start-of-day key.
    private struct FileState {
        var offset: UInt64 = 0
        var total = UsageTotals()
        var byDay: [Int: UsageTotals] = [:]
        var seenIds: Set<String> = []
    }
    private var files: [String: FileState] = [:]

    private let calendar = Calendar.current
    /// Drop day buckets older than this so `byDay` stays bounded over months.
    private let retainedDays = 40

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")) {
        self.projectsDir = claudeDir.appendingPathComponent("projects")
    }

    /// Re-read what changed and return a fresh snapshot.
    func scan(now: Date = Date()) -> UsageSnapshot {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]).flatMap(transcripts(in:)) else {
            return UsageSnapshot()
        }

        let live = Set(urls.map(\.path))
        files = files.filter { live.contains($0.key) }  // forget deleted files

        for url in urls { updateFile(url) }

        return summarize(now: now)
    }

    // MARK: - Incremental file parsing

    private func updateFile(_ url: URL) {
        let path = url.path
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { UInt64($0) } ?? 0

        var state = files[path] ?? FileState()
        // File shrank or was replaced → re-parse from the top.
        if size < state.offset { state = FileState() }
        guard size > state.offset else { files[path] = state; return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else {
            files[path] = state
            return
        }

        // Only consume up to the last newline; a trailing partial line will be
        // re-read (from the advanced-but-not-past-it offset) once it's complete.
        guard let lastNL = chunk.lastIndex(of: 0x0A) else {
            files[path] = state  // no complete line yet
            return
        }
        let complete = chunk[...lastNL]
        state.offset += UInt64(complete.count)

        if let text = String(data: complete, encoding: .utf8) {
            text.enumerateLines { line, _ in
                guard let parsed = UsageParser.parseLine(line) else { return }
                if let id = parsed.id {
                    guard !state.seenIds.contains(id) else { return }
                    state.seenIds.insert(id)
                }
                state.total += parsed.totals
                if let day = parsed.timestamp.map(self.dayKey) {
                    state.byDay[day, default: UsageTotals()] += parsed.totals
                }
            }
        }

        prune(&state.byDay)
        files[path] = state
    }

    // MARK: - Summary

    private func summarize(now: Date) -> UsageSnapshot {
        let todayKey = dayKey(now)
        let earliest = todayKey - 29
        var snap = UsageSnapshot()
        for (path, state) in files {
            let sessionId = (path as NSString).lastPathComponent
                .replacingOccurrences(of: ".jsonl", with: "")
            snap.perSession[sessionId] = state.total
            snap.lifetime += state.total
            for (day, totals) in state.byDay {
                if day == todayKey { snap.today += totals }
                if day >= earliest { snap.last30 += totals }
            }
        }
        return snap
    }

    // MARK: - Helpers

    private func dayKey(_ date: Date) -> Int {
        Int(calendar.startOfDay(for: date).timeIntervalSinceReferenceDate / 86_400)
    }

    private func prune(_ byDay: inout [Int: UsageTotals]) {
        guard let newest = byDay.keys.max() else { return }
        let cutoff = newest - retainedDays
        byDay = byDay.filter { $0.key >= cutoff }
    }

    /// All `*.jsonl` transcripts directly inside a project directory.
    private func transcripts(in dir: URL) -> [URL] {
        guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles])
        else { return [] }
        return contents.filter { $0.pathExtension == "jsonl" }
    }
}
