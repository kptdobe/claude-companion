import XCTest
@testable import ClaudeCompanion

final class EntrypointTests: XCTestCase {
    func testKnownEntrypointsMapToLabels() {
        XCTAssertEqual(Entrypoint(raw: "cli"), .cli)
        XCTAssertEqual(Entrypoint(raw: "claude-vscode"), .vscode)
        XCTAssertEqual(Entrypoint(raw: "claude-desktop"), .desktop)
        XCTAssertEqual(Entrypoint(raw: "sdk-cli"), .sdk)
        XCTAssertEqual(Entrypoint(raw: "cli").label, "Terminal")
        XCTAssertEqual(Entrypoint(raw: "claude-vscode").label, "VS Code")
    }

    func testNilAndGarbageBecomeUnknown() {
        XCTAssertEqual(Entrypoint(raw: nil), .unknown)
        XCTAssertEqual(Entrypoint(raw: "wat"), .unknown)
        XCTAssertEqual(Entrypoint(raw: "").label, "Unknown")
    }
}

final class SessionActivityTests: XCTestCase {
    func testHookEventsMapToActivities() {
        XCTAssertEqual(SessionActivity.from(hookEvent: "UserPromptSubmit"), .thinking)
        XCTAssertEqual(SessionActivity.from(hookEvent: "PreToolUse"), .thinking)
        XCTAssertEqual(SessionActivity.from(hookEvent: "PostToolUse"), .thinking)
        XCTAssertEqual(SessionActivity.from(hookEvent: "Notification"), .waiting)
        XCTAssertEqual(SessionActivity.from(hookEvent: "Stop"), .idle)
        XCTAssertEqual(SessionActivity.from(hookEvent: "SubagentStop"), .idle)
    }

    func testUnknownEventIsUnknown() {
        XCTAssertEqual(SessionActivity.from(hookEvent: "MadeUpEvent"), .unknown)
    }

    func testSortRankPrioritisesAttention() {
        XCTAssertLessThan(SessionActivity.waiting.sortRank, SessionActivity.thinking.sortRank)
        XCTAssertLessThan(SessionActivity.thinking.sortRank, SessionActivity.idle.sortRank)
        XCTAssertLessThan(SessionActivity.idle.sortRank, SessionActivity.unknown.sortRank)
    }
}

final class DecodingTests: XCTestCase {
    func testDecodeSessionRecordFromRealShape() {
        let json = """
        {"pid":24143,"sessionId":"abc","cwd":"/Users/me/proj","startedAt":1782137344543,
         "version":"2.1.181","kind":"interactive","entrypoint":"claude-desktop"}
        """.data(using: .utf8)!
        let record = SessionRecord.decode(json)
        XCTAssertEqual(record?.pid, 24143)
        XCTAssertEqual(record?.sessionId, "abc")
        XCTAssertEqual(record?.cwd, "/Users/me/proj")
        XCTAssertEqual(record?.entrypoint, "claude-desktop")
    }

    func testDecodeStateRecordYieldsActivity() {
        let json = #"{"sessionId":"abc","state":"waiting","event":"Notification","ts":1782137344}"#
            .data(using: .utf8)!
        let state = StateRecord.decode(json)
        XCTAssertEqual(state?.activity, .waiting)
        XCTAssertEqual(state?.event, "Notification")
    }

    func testDecodeIDELockFromRealShape() {
        let json = """
        {"pid":9005,"workspaceFolders":["/Users/me/proj"],"ideName":"Visual Studio Code",
         "transport":"ws","authToken":"x"}
        """.data(using: .utf8)!
        let lock = IDELock.decode(json)
        XCTAssertEqual(lock?.workspaceFolders, ["/Users/me/proj"])
        XCTAssertEqual(lock?.ideName, "Visual Studio Code")
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(SessionRecord.decode(Data("not json".utf8)))
        XCTAssertNil(StateRecord.decode(Data("{}".utf8)))
    }
}

final class SessionMergerTests: XCTestCase {
    private func record(_ id: String, pid: Int, cwd: String = "/p",
                        entrypoint: String = "cli") -> SessionRecord {
        SessionRecord(pid: pid, sessionId: id, cwd: cwd, startedAt: 1_000_000,
                      version: nil, kind: nil, entrypoint: entrypoint)
    }
    private func state(_ id: String, _ s: String, ts: Double) -> StateRecord {
        StateRecord(sessionId: id, state: s, event: nil, cwd: nil, ts: ts)
    }

    func testDeadProcessesAreDropped() {
        let records = [record("live", pid: 1), record("dead", pid: 2)]
        let merged = SessionMerger.merge(
            records: records, states: [:], isAlive: { $0 == 1 })
        XCTAssertEqual(merged.map(\.id), ["live"])
    }

    func testActivityComesFromStateAndDefaultsToUnknown() {
        let records = [record("a", pid: 1), record("b", pid: 2)]
        let states = ["a": state("a", "thinking", ts: 10)]
        let merged = SessionMerger.merge(
            records: records, states: states, isAlive: { _ in true })
        let byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        XCTAssertEqual(byId["a"]?.activity, .thinking)
        XCTAssertEqual(byId["b"]?.activity, .unknown)
    }

    func testSortingPutsWaitingFirstThenThinkingThenIdle() {
        let records = [
            record("idle", pid: 1), record("waiting", pid: 2), record("thinking", pid: 3),
        ]
        let states = [
            "idle": state("idle", "idle", ts: 30),
            "waiting": state("waiting", "waiting", ts: 20),
            "thinking": state("thinking", "thinking", ts: 10),
        ]
        let merged = SessionMerger.merge(
            records: records, states: states, isAlive: { _ in true })
        XCTAssertEqual(merged.map(\.id), ["waiting", "thinking", "idle"])
    }

    func testActiveDropsUnknownSessions() {
        // "b" has no state (pre-companion session) → unknown → hidden.
        let records = [record("a", pid: 1), record("b", pid: 2)]
        let states = ["a": state("a", "idle", ts: 5)]
        let merged = SessionMerger.merge(
            records: records, states: states, isAlive: { _ in true })
        let active = SessionMerger.active(merged)
        XCTAssertEqual(active.map(\.id), ["a"])
        XCTAssertEqual(merged.count, 2, "merge still reports the full truth")
    }

    func testAnyThinkingAndWaitingCount() {
        let records = [record("a", pid: 1), record("b", pid: 2), record("c", pid: 3)]
        let states = [
            "a": state("a", "thinking", ts: 1),
            "b": state("b", "waiting", ts: 1),
            "c": state("c", "waiting", ts: 1),
        ]
        let merged = SessionMerger.merge(
            records: records, states: states, isAlive: { _ in true })
        XCTAssertTrue(SessionMerger.anyThinking(merged))
        XCTAssertEqual(SessionMerger.waitingCount(merged), 2)
    }

    func testTitleIsDirectoryBasename() {
        let merged = SessionMerger.merge(
            records: [record("a", pid: 1, cwd: "/Users/me/work/da-live")],
            states: [:], isAlive: { _ in true })
        XCTAssertEqual(merged.first?.title, "da-live")
    }
}

final class TranscriptTitleTests: XCTestCase {
    func testCustomTitleWinsOverAITitle() {
        let jsonl = """
        {"type":"user","message":"hi"}
        {"type":"ai-title","aiTitle":"Build macOS Claude companion control center","sessionId":"x"}
        {"type":"custom-title","customTitle":"macOS Claude companion app","sessionId":"x"}
        """.data(using: .utf8)!
        XCTAssertEqual(TranscriptTitle.extract(fromTranscript: jsonl), "macOS Claude companion app")
    }

    func testFallsBackToAITitle() {
        let jsonl = """
        {"type":"assistant","message":"working"}
        {"type":"ai-title","aiTitle":"Fix the auth bug","sessionId":"x"}
        """.data(using: .utf8)!
        XCTAssertEqual(TranscriptTitle.extract(fromTranscript: jsonl), "Fix the auth bug")
    }

    func testReturnsNilWhenNoTitleLines() {
        let jsonl = """
        {"type":"user","message":"hi"}
        {"type":"last-prompt","lastPrompt":"do a thing"}
        """.data(using: .utf8)!
        XCTAssertNil(TranscriptTitle.extract(fromTranscript: jsonl))
    }

    func testSessionTitlePrefersCustomTitleOverFolder() {
        var session = Session(id: "x", pid: 1, cwd: "/Users/me/work/da-live",
                              entrypoint: .vscode, activity: .idle, lastActivity: Date())
        XCTAssertEqual(session.title, "da-live")
        session.customTitle = "Fix RUM 500"
        XCTAssertEqual(session.title, "Fix RUM 500")
    }
}

final class WindowActivatorTests: XCTestCase {
    func testBestWorkspacePicksContainingFolder() {
        let locks = [
            IDELock(pid: 1, workspaceFolders: ["/Users/me/work"], ideName: "Visual Studio Code"),
            IDELock(pid: 2, workspaceFolders: ["/Users/me/work/da-live"], ideName: "Visual Studio Code"),
        ]
        // Deepest matching workspace wins.
        XCTAssertEqual(
            WindowActivator.bestWorkspace(for: "/Users/me/work/da-live/src", in: locks),
            "/Users/me/work/da-live")
    }

    func testBestWorkspaceReturnsNilWhenNoMatch() {
        let locks = [IDELock(pid: 1, workspaceFolders: ["/a/b"], ideName: "X")]
        XCTAssertNil(WindowActivator.bestWorkspace(for: "/c/d", in: locks))
    }

    func testBestWorkspaceRequiresPathBoundary() {
        // "/a/proj-2" must NOT match workspace "/a/proj".
        let locks = [IDELock(pid: 1, workspaceFolders: ["/a/proj"], ideName: "X")]
        XCTAssertNil(WindowActivator.bestWorkspace(for: "/a/proj-2", in: locks))
    }
}
