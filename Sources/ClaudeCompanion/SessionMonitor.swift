import Foundation

/// Pure merge logic: combines the live-session registry with hook-written
/// state into the displayable session list. Kept free of I/O so it can be
/// unit-tested as a black box.
enum SessionMerger {
    /// - Parameters:
    ///   - records: decoded `sessions/<pid>.json` entries.
    ///   - states: hook state keyed by sessionId.
    ///   - isAlive: returns true if a pid is still running.
    ///   - now: current time (injectable for tests).
    ///   - thinkingTimeout: a `thinking` state with no update for longer than
    ///     this is treated as stale (crashed/orphaned turn) and demoted to
    ///     `.unknown`, so it stops spinning the icon and drops out of the list.
    static func merge(
        records: [SessionRecord],
        states: [String: StateRecord],
        isAlive: (Int) -> Bool,
        now: Date = Date(),
        thinkingTimeout: TimeInterval = 600
    ) -> [Session] {
        var sessions: [Session] = []

        for record in records where isAlive(record.pid) {
            let state = states[record.sessionId]
            var activity = state?.activity ?? .unknown

            let last: Date
            if let ts = state?.ts {
                last = Date(timeIntervalSince1970: ts)
            } else if let started = record.startedAt {
                last = Date(timeIntervalSince1970: started / 1000.0)
            } else {
                last = now
            }

            // Demote a "thinking" state that has gone quiet for too long.
            if activity == .thinking, now.timeIntervalSince(last) > thinkingTimeout {
                activity = .unknown
            }

            sessions.append(Session(
                id: record.sessionId,
                pid: record.pid,
                cwd: record.cwd,
                entrypoint: Entrypoint(raw: record.entrypoint),
                activity: activity,
                lastActivity: last
            ))
        }

        // Most-relevant first (waiting → thinking → idle), then most recent.
        return sessions.sorted { a, b in
            if a.activity.sortRank != b.activity.sortRank {
                return a.activity.sortRank < b.activity.sortRank
            }
            return a.lastActivity > b.lastActivity
        }
    }

    /// Sessions worth displaying: those that have reported state via a hook.
    /// Sessions started before the companion (no hook state yet) are `.unknown`
    /// and are dropped so the menu shows only sessions it can speak about.
    static func active(_ sessions: [Session]) -> [Session] {
        sessions.filter { $0.activity != .unknown }
    }

    /// True if any session is actively working — drives the animated icon.
    static func anyThinking(_ sessions: [Session]) -> Bool {
        sessions.contains { $0.activity == .thinking }
    }

    /// Count of sessions awaiting your input — drives the badge.
    static func waitingCount(_ sessions: [Session]) -> Int {
        sessions.filter { $0.activity == .waiting }.count
    }
}

/// Watches the `~/.claude` directories and publishes a merged session list.
final class SessionMonitor {
    private let claudeDir: URL
    private var sessionsDir: URL { claudeDir.appendingPathComponent("sessions") }
    private var stateDir: URL { claudeDir.appendingPathComponent("companion-state") }

    private var timer: Timer?
    private(set) var sessions: [Session] = []

    /// Called on the main thread whenever the merged list changes.
    var onChange: (([Session]) -> Void)?

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
    }

    func start(interval: TimeInterval = 1.5) {
        try? FileManager.default.createDirectory(
            at: stateDir, withIntermediateDirectories: true)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-read disk and publish if the list changed.
    func refresh() {
        let records = readRecords()
        let states = readStates()
        let merged = SessionMerger.merge(
            records: records, states: states, isAlive: Self.isAlive)
        if merged != sessions {
            sessions = merged
            onChange?(merged)
        }
    }

    private func readRecords() -> [SessionRecord] {
        readJSONFiles(in: sessionsDir, ext: "json").compactMap(SessionRecord.decode)
    }

    private func readStates() -> [String: StateRecord] {
        var map: [String: StateRecord] = [:]
        for data in readJSONFiles(in: stateDir, ext: "json") {
            if let s = StateRecord.decode(data) { map[s.sessionId] = s }
        }
        return map
    }

    private func readJSONFiles(in dir: URL, ext: String) -> [Data] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return names
            .filter { $0.pathExtension == ext }
            .compactMap { try? Data(contentsOf: $0) }
    }

    /// POSIX liveness check: signal 0 probes without sending anything.
    static func isAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}
