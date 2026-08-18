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
    ///   - idleTimeout: a non-tool `thinking` state quiet for longer than this
    ///     is treated as a turn that ended without a `Stop`/`SessionEnd` hook —
    ///     an interrupt (Esc doesn't fire `Stop`) or a dropped terminal event —
    ///     and demoted to `.idle`, so the spinner clears to "done" instead of
    ///     spinning until `thinkingTimeout`. Demoting to `.idle` (not `.unknown`)
    ///     is deliberately safe: if the session was in fact still generating, the
    ///     next hook refreshes its timestamp and it flips straight back.
    ///   - thinkingTimeout: a `thinking` state with no update for even longer is
    ///     treated as stale (crashed/orphaned turn) and demoted to `.unknown`, so
    ///     it stops spinning the icon and drops out of the list entirely.
    ///   - pendingToolTimeout: a `PreToolUse` (tool about to run) with no
    ///     completion for longer than this is almost certainly blocked on a
    ///     permission prompt — there is no `Notification` hook for that — so it
    ///     is promoted to `.waiting`.
    static func merge(
        records: [SessionRecord],
        states: [String: StateRecord],
        isAlive: (Int) -> Bool,
        now: Date = Date(),
        idleTimeout: TimeInterval = 120,
        thinkingTimeout: TimeInterval = 600,
        pendingToolTimeout: TimeInterval = 15
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

            // Re-interpret a "thinking" state by how long it's been quiet and
            // what it was doing when it went quiet:
            //  - a tool pending (PreToolUse) with no completion past the
            //    auto-approval window is blocked on a permission prompt (no
            //    Notification hook fires for those) → .waiting, and it STAYS
            //    waiting however long, so you don't forget it after stepping away;
            //  - non-tool "thinking" quiet past the very long window is a
            //    crashed/orphaned turn → hide (.unknown);
            //  - non-tool "thinking" quiet past the shorter window is a turn that
            //    ended without a Stop hook (an Esc interrupt doesn't fire Stop) →
            //    .idle, so the icon stops spinning and shows "done".
            if activity == .thinking {
                let quiet = now.timeIntervalSince(last)
                if state?.event == "PreToolUse", quiet > pendingToolTimeout {
                    activity = .waiting
                } else if quiet > thinkingTimeout {
                    activity = .unknown
                } else if quiet > idleTimeout {
                    activity = .idle
                }
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

    /// Token/cost usage, scanned off the main thread (transcripts can be large).
    private let usageStore: UsageStore
    private let usageQueue = DispatchQueue(label: "com.acapt.claude-companion.usage")
    private var usageBusy = false
    private var lastUsageScan: Date = .distantPast
    private(set) var usage = UsageSnapshot()

    /// headroom.ai savings, polled off the main thread (spawns a CLI process).
    private var headroomBusy = false
    private var lastHeadroomScan: Date = .distantPast
    private(set) var headroom: HeadroomSavings?
    /// Subscription usage limits from headroom's polled cache.
    private(set) var subscription: SubscriptionUsage?
    /// Live compression-proxy health from its `/health` endpoint.
    private(set) var health: HeadroomHealth?

    /// Called on the main thread whenever the merged list changes.
    var onChange: (([Session]) -> Void)?
    /// Called on the main thread whenever the usage snapshot changes.
    var onUsage: ((UsageSnapshot) -> Void)?
    /// Called on the main thread whenever the headroom savings change.
    var onHeadroom: ((HeadroomSavings?) -> Void)?
    /// Called on the main thread whenever the subscription usage changes.
    var onSubscription: ((SubscriptionUsage?) -> Void)?
    /// Called on the main thread whenever the proxy health changes.
    var onHealth: ((HeadroomHealth?) -> Void)?

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
        self.usageStore = UsageStore(claudeDir: claudeDir)
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
        refreshUsage()
        refreshHeadroom()
    }

    /// Kick off a background usage scan at most every few seconds, coalescing
    /// so a slow first pass never stacks up behind the 1.5s timer.
    private func refreshUsage(minInterval: TimeInterval = 4) {
        guard !usageBusy, Date().timeIntervalSince(lastUsageScan) >= minInterval else { return }
        usageBusy = true
        usageQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.usageStore.scan()
            DispatchQueue.main.async {
                self.usageBusy = false
                self.lastUsageScan = Date()
                if snapshot != self.usage {
                    self.usage = snapshot
                    self.onUsage?(snapshot)
                }
            }
        }
    }

    /// Poll headroom savings on a slow cadence (each call spawns a process).
    private func refreshHeadroom(minInterval: TimeInterval = 20) {
        guard !headroomBusy, Date().timeIntervalSince(lastHeadroomScan) >= minInterval else { return }
        headroomBusy = true
        usageQueue.async { [weak self] in
            let savings = HeadroomStore.fetchSavings()
            let subscription = HeadroomStore.readSubscription()
            let health = HeadroomStore.fetchHealth()
            DispatchQueue.main.async {
                guard let self else { return }
                self.headroomBusy = false
                self.lastHeadroomScan = Date()
                if savings != self.headroom {
                    self.headroom = savings
                    self.onHeadroom?(savings)
                }
                if subscription != self.subscription {
                    self.subscription = subscription
                    self.onSubscription?(subscription)
                }
                if health != self.health {
                    self.health = health
                    self.onHealth?(health)
                }
            }
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
