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
        // Orange is only for "needs your input to proceed".
        XCTAssertEqual(SessionActivity.from(hookEvent: "Notification"), .waiting)
        // Stop = the turn ended with nothing required from you → done (green).
        XCTAssertEqual(SessionActivity.from(hookEvent: "Stop"), .idle)
        // A subagent finishing doesn't end the main turn — Claude keeps working.
        XCTAssertEqual(SessionActivity.from(hookEvent: "SubagentStop"), .thinking)
        // The whole session closing is "done".
        XCTAssertEqual(SessionActivity.from(hookEvent: "SessionEnd"), .idle)
    }

    func testUnknownEventIsUnknown() {
        XCTAssertEqual(SessionActivity.from(hookEvent: "MadeUpEvent"), .unknown)
    }

    func testLooksLikeQuestionFlagsClosingQuestions() {
        XCTAssertTrue(SessionActivity.looksLikeQuestion("Want me to ship it?"))
        // A question with a trailing default still counts.
        XCTAssertTrue(SessionActivity.looksLikeQuestion(
            "Keep 15s or go longer? I'll use 15s otherwise."))
        // Plain "done" reports are not questions.
        XCTAssertFalse(SessionActivity.looksLikeQuestion("Done. Shipped v0.1.3."))
        XCTAssertFalse(SessionActivity.looksLikeQuestion("All 33 tests pass."))
    }

    func testBlockingToolPreUseIsWaiting() {
        // AskUserQuestion / ExitPlanMode block for the user's answer — even
        // though they arrive as a PreToolUse (which is normally "thinking").
        XCTAssertEqual(
            SessionActivity.from(hookEvent: "PreToolUse", toolName: "AskUserQuestion"),
            .waiting)
        XCTAssertEqual(
            SessionActivity.from(hookEvent: "PreToolUse", toolName: "ExitPlanMode"),
            .waiting)
    }

    func testNonBlockingToolPreUseIsThinking() {
        XCTAssertEqual(
            SessionActivity.from(hookEvent: "PreToolUse", toolName: "Bash"),
            .thinking)
    }

    func testToolNameIgnoredForNonPreToolUseEvents() {
        // A tool name on Stop shouldn't change the meaning of Stop (done).
        XCTAssertEqual(
            SessionActivity.from(hookEvent: "Stop", toolName: "AskUserQuestion"),
            .idle)
        XCTAssertEqual(
            SessionActivity.from(hookEvent: "PostToolUse", toolName: "AskUserQuestion"),
            .thinking)
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
    private func state(_ id: String, _ s: String, ts: Double,
                       event: String? = nil) -> StateRecord {
        StateRecord(sessionId: id, state: s, event: event, cwd: nil, ts: ts)
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
            records: records, states: states, isAlive: { _ in true },
            now: Date(timeIntervalSince1970: 60))
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
            records: records, states: states, isAlive: { _ in true },
            now: Date(timeIntervalSince1970: 60))
        XCTAssertEqual(merged.map(\.id), ["waiting", "thinking", "idle"])
    }

    func testStaleThinkingIsDemotedAndHidden() {
        // The reported bug: one session is waiting on the user while another
        // crashed mid-tool 15h ago and is stuck "thinking" — keeping the icon
        // spinning blue. The stale one must be demoted so it neither spins the
        // icon nor clutters the list.
        let now = Date(timeIntervalSince1970: 100_000)
        let records = [record("waiting", pid: 1), record("zombie", pid: 2),
                       record("fresh", pid: 3)]
        let states = [
            "waiting": state("waiting", "waiting", ts: now.timeIntervalSince1970 - 5),
            // crashed mid-generation (not a pending tool) → should be hidden
            "zombie": state("zombie", "thinking",
                            ts: now.timeIntervalSince1970 - 3600, event: "UserPromptSubmit"),
            "fresh": state("fresh", "thinking", ts: now.timeIntervalSince1970 - 5),
        ]
        let merged = SessionMerger.merge(
            records: records, states: states, isAlive: { _ in true },
            now: now, thinkingTimeout: 600)
        let byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        XCTAssertEqual(byId["zombie"]?.activity, .unknown, "stale thinking demoted")
        XCTAssertEqual(byId["fresh"]?.activity, .thinking, "recent thinking preserved")
        XCTAssertEqual(byId["waiting"]?.activity, .waiting)
        // Only the genuinely-active 'fresh' should spin the icon, not the zombie.
        XCTAssertEqual(SessionMerger.active(merged).map { $0.id }.sorted(),
                       ["fresh", "waiting"], "zombie hidden")
    }

    func testPendingToolPromptBecomesWaiting() {
        // No Notification hook fires for permission prompts, so a tool stuck on
        // PreToolUse (not completed) for a while means Claude is blocked on you.
        let now = Date(timeIntervalSince1970: 100_000)
        let records = [record("quick", pid: 1), record("blocked", pid: 2),
                       record("generating", pid: 3)]
        let states = [
            // tool just started — still legitimately working
            "quick": state("quick", "thinking",
                           ts: now.timeIntervalSince1970 - 3, event: "PreToolUse"),
            // tool pending 30s with no PostToolUse — a permission prompt
            "blocked": state("blocked", "thinking",
                             ts: now.timeIntervalSince1970 - 30, event: "PreToolUse"),
            // long response generation is NOT a pending tool — keep working
            "generating": state("generating", "thinking",
                                ts: now.timeIntervalSince1970 - 30, event: "UserPromptSubmit"),
        ]
        let merged = SessionMerger.merge(
            records: records, states: states, isAlive: { _ in true },
            now: now, thinkingTimeout: 600, pendingToolTimeout: 15)
        let byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        XCTAssertEqual(byId["quick"]?.activity, .thinking)
        XCTAssertEqual(byId["blocked"]?.activity, .waiting, "pending tool → permission prompt")
        XCTAssertEqual(byId["generating"]?.activity, .thinking, "generation is not a pending tool")
    }

    func testLongPendingToolStaysWaiting() {
        // A permission prompt you walked away from must NOT be hidden — that's
        // the whole point of the app. A pending tool stays waiting however long.
        let now = Date(timeIntervalSince1970: 100_000)
        let records = [record("away", pid: 1)]
        let states = ["away": state("away", "thinking",
                                    ts: now.timeIntervalSince1970 - 7200, event: "PreToolUse")]
        let merged = SessionMerger.merge(
            records: records, states: states, isAlive: { _ in true },
            now: now, thinkingTimeout: 600, pendingToolTimeout: 15)
        XCTAssertEqual(merged.first?.activity, .waiting)
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
            records: records, states: states, isAlive: { _ in true },
            now: Date(timeIntervalSince1970: 60))
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

    func testSessionTitleLeadsWithIssueKeyForPaperclip() {
        // A Paperclip session's cwd is a workspace UUID — never show that.
        var session = Session(
            id: "x", pid: 1,
            cwd: "/Users/me/.paperclip/instances/default/workspaces/69379141-4656-4096",
            entrypoint: .sdk, activity: .thinking, lastActivity: Date())
        // No title yet: show the issue key, not the UUID.
        session.issueKey = "COR-61"
        XCTAssertEqual(session.title, "COR-61")
        // With a title: lead with the key, then the summary.
        session.customTitle = "Investigate writeAuditEntry shard convergence failures"
        XCTAssertEqual(session.title,
                       "COR-61  ·  Investigate writeAuditEntry shard convergence failures")
    }

    func testNonSDKSessionIgnoresStrayIssueKey() {
        // A Desktop/VS Code session whose transcript merely mentions an issue
        // key (e.g. while discussing it) must NOT show it as the title.
        var session = Session(id: "x", pid: 1, cwd: "/Users/me/work/claude-companion",
                              entrypoint: .desktop, activity: .thinking, lastActivity: Date())
        session.issueKey = "COR-95"
        session.customTitle = "macOS Claude companion app"
        XCTAssertEqual(session.title, "macOS Claude companion app")
        session.customTitle = nil
        XCTAssertEqual(session.title, "claude-companion")
    }
}

final class TranscriptInfoTests: XCTestCase {
    func testExtractInfoReturnsTitleAndIssueKey() {
        let jsonl = """
        {"type":"ai-title","aiTitle":"Investigate shard convergence","sessionId":"x"}
        {"type":"user","message":{"content":"## Paperclip Wake Payload\\n- issue: COR-61 writeAuditEntry shard"}}
        """.data(using: .utf8)!
        let info = TranscriptTitle.extractInfo(fromTranscript: jsonl)
        XCTAssertEqual(info.title, "Investigate shard convergence")
        XCTAssertEqual(info.issueKey, "COR-61")
    }

    func testExtractInfoNonPaperclipHasNoIssueKey() {
        let jsonl = """
        {"type":"ai-title","aiTitle":"Fix the bug","sessionId":"x"}
        """.data(using: .utf8)!
        let info = TranscriptTitle.extractInfo(fromTranscript: jsonl)
        XCTAssertEqual(info.title, "Fix the bug")
        XCTAssertNil(info.issueKey)
    }
}

final class PaperclipTests: XCTestCase {
    func testIssueKeyFromWakePayload() {
        let transcript = """
        {"type":"user","message":{"content":"## Paperclip Wake Payload\\n- issue: COR-95 da-content `memory limit` — stream body"}}
        """
        XCTAssertEqual(Paperclip.issueKey(fromTranscript: transcript), "COR-95")
    }

    func testIssueKeyUsesMostRecentWake() {
        // Two heartbeats; the latest issue is the current one.
        let transcript = """
        - issue: COR-94 da-live `first task`
        ...later heartbeat...
        - issue: COR-95 da-content `second task`
        """
        XCTAssertEqual(Paperclip.issueKey(fromTranscript: transcript), "COR-95")
    }

    func testNonPaperclipTranscriptHasNoIssueKey() {
        XCTAssertNil(Paperclip.issueKey(fromTranscript: "just a normal session, no wake here"))
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

final class WindowFocuserTests: XCTestCase {
    func testExactFolderSegmentScoresHighest() {
        // VS Code titles join parts with an em dash.
        XCTAssertEqual(
            WindowFocuser.matchScore(
                title: "Models.swift — claude-companion — Workspace",
                workspaceFolder: "/Users/me/claude-companion"),
            2)
    }

    func testTitleEqualToFolderNameMatches() {
        // No editor open: VS Code shows just the root name.
        XCTAssertEqual(
            WindowFocuser.matchScore(
                title: "claude-companion",
                workspaceFolder: "/Users/me/claude-companion"),
            2)
    }

    func testSubstringOnlyScoresLower() {
        // A different window whose name merely contains the folder name.
        XCTAssertEqual(
            WindowFocuser.matchScore(
                title: "readme — claude-companion-tools",
                workspaceFolder: "/Users/me/claude-companion"),
            1)
    }

    func testNoMatchScoresZero() {
        XCTAssertEqual(
            WindowFocuser.matchScore(
                title: "index.js — da-live",
                workspaceFolder: "/Users/me/claude-companion"),
            0)
    }

    func testExactSegmentBeatsSubstringWhenChoosing() {
        // The real window (exact segment) must outrank a look-alike (substring),
        // so the correct window is chosen when several are similar.
        let folder = "/Users/me/da-live"
        let real = WindowFocuser.matchScore(title: "app.js — da-live", workspaceFolder: folder)
        let lookalike = WindowFocuser.matchScore(title: "x — da-live-tools", workspaceFolder: folder)
        XCTAssertGreaterThan(real, lookalike)
    }
}
