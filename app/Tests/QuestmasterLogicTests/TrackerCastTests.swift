import Foundation
import QuestmasterCore

struct TrackerCastTests {
    static func run() {
        castAndNarrationDecodeFromASession()
        missingCastAndNarrationDecodeAsNone()
        unknownTypicalDurationShimmers()
        fillReachesFullAtTypicalAndHolds()
        timeToFullCountsDownToTheTypicalDuration()
        phaseOpensFinishesAndReplaces()
        labelIsTheChatsCallLabel()
        snippetPrefersNarrationOnOneLine()
        portraitRingMirrorsTheCast()
        sameCallIgnoresTheLearnedDuration()
        barHoldsItsFinishWhileTheRowCloses()
        symbolsCoverEachAgentsTools()
        print("TrackerCastTests: all tests passed")
    }

    private static func session(_ extra: String) throws -> TrackerSession {
        let json = """
        {"id": "qm-1", "title": "Review PRs", "status": "active", "worker_count": 0, "elapsed_ms": 0, "is_current": false, "agent": "codex"\(extra)}
        """
        return try JSONDecoder().decode(TrackerSession.self, from: Data(json.utf8))
    }

    private static func castAndNarrationDecodeFromASession() {
        do {
            let decoded = try session("""
            , "narration": "It seems that something is still failing.", "cast": {"tool": "Bash", "started_at": "2026-10-20T07:33:48.529Z", "typical_ms": 6000}
            """)
            expect(decoded.narration == "It seems that something is still failing.", "narration should decode, got \(decoded.narration)")
            guard let cast = decoded.cast else { fail("cast should decode") }
            expect(cast.tool == "Bash" && cast.typicalMS == 6000, "cast fields should decode, got \(cast)")
            let expected = Date(timeIntervalSince1970: 1_792_481_628.529)
            expect(abs(cast.startedAt.timeIntervalSince(expected)) < 0.001, "started_at should keep its milliseconds, got \(cast.startedAt)")
            expect(cast.typicalDuration == 6, "typical_ms should read as 6 seconds")
        } catch {
            fail("a session with cast and narration should decode: \(error)")
        }
    }

    private static func missingCastAndNarrationDecodeAsNone() {
        do {
            let plain = try session("")
            expect(plain.cast == nil && plain.narration.isEmpty, "a session without the fields should have no cast and no narration")
            let null = try session(", \"cast\": null, \"narration\": \"\"")
            expect(null.cast == nil && null.narration.isEmpty, "a null cast should decode as none")
        } catch {
            fail("a session without cast or narration should decode: \(error)")
        }
    }

    private static func unknownTypicalDurationShimmers() {
        let unknown = TrackerCast(tool: "mcp__linear__save_issue", startedAt: Date(), typicalMS: 0)
        expect(unknown.typicalDuration == nil, "typical_ms 0 means no learned duration, so the bar shimmers")
    }

    private static func fillReachesFullAtTypicalAndHolds() {
        let typical = 6.0
        expect(TrackerCastFill.fraction(elapsed: 0, typical: typical) == 0, "the bar starts empty")
        expect(TrackerCastFill.fraction(elapsed: -2, typical: typical) == 0, "a start in the future reads as empty")
        expect(abs(TrackerCastFill.fraction(elapsed: 3, typical: typical) - 0.5) < 1e-9, "halfway to the typical time is half full")
        expect(TrackerCastFill.fraction(elapsed: typical, typical: typical) == 1, "the typical time is full")
        expect(TrackerCastFill.fraction(elapsed: 10 * typical, typical: typical) == 1, "an overrunning tool holds the bar full")
    }

    private static func timeToFullCountsDownToTheTypicalDuration() {
        expect(TrackerCastFill.timeToFull(elapsed: 2, typical: 6) == 4, "2s into a 6s tool the bar fills in 4s")
        expect(TrackerCastFill.timeToFull(elapsed: -1, typical: 6) == 6, "a start in the future fills over the whole duration")
        expect(TrackerCastFill.timeToFull(elapsed: 9, typical: 6) == 0, "an overrunning tool is already full")
    }

    private static func phaseOpensFinishesAndReplaces() {
        let bash = TrackerCast(tool: "Bash", startedAt: Date(timeIntervalSince1970: 100), typicalMS: 6000)
        let edit = TrackerCast(tool: "Edit", startedAt: Date(timeIntervalSince1970: 200), typicalMS: 1000)
        let hidden = TrackerCastPhase.hidden
        expect(hidden.next(cast: nil, status: .working) == .hidden, "with no cast the row stays hidden")
        expect(hidden.next(cast: bash, status: .working) == .casting(bash), "a cast opens the row")
        expect(TrackerCastPhase.casting(bash).next(cast: nil, status: .working) == .finishing(bash), "an ended cast finishes")
        expect(TrackerCastPhase.finishing(bash).next(cast: nil, status: .working) == .finishing(bash), "a finishing row waits for its own end")
        expect(TrackerCastPhase.finishing(bash).next(cast: edit, status: .working) == .casting(edit), "a new cast replaces a finishing one at once")
        expect(TrackerCastPhase.casting(bash).next(cast: edit, status: .working) == .casting(edit), "the latest cast replaces the running one")
        for status in [TrackerStatusKind.blocked, .needsInput] {
            expect(TrackerCastPhase.casting(bash).next(cast: bash, status: status) == .hidden, "\(status) hides a running cast without the finish flash")
            expect(hidden.next(cast: bash, status: status) == .hidden, "\(status) keeps a new cast hidden")
        }
        expect(hidden.next(cast: bash, status: .working) == .casting(bash), "leaving the pending status shows the running cast again")
        expect(TrackerCastPhase.casting(bash).next(cast: bash, status: .error) == .casting(bash), "an error keeps the cast showing")
        expect(!hidden.isOpen && TrackerCastPhase.finishing(bash).isOpen, "only a hidden row is closed")
        expect(TrackerCastPhase.finishing(bash).cast == bash && hidden.cast == nil, "the row shows its own cast until hidden")
    }

    private static func labelIsTheChatsCallLabel() {
        let bash = TrackerCast(tool: "Bash", startedAt: Date(), typicalMS: 6000)
        let mcp = TrackerCast(tool: "mcp__linear__save_issue", startedAt: Date(), typicalMS: 0)
        expect(bash.label == "[Bash]", "the label should be the chat's, got \(bash.label)")
        expect(mcp.label == WorkerChatLineBuilder.callLabel(name: "mcp__linear__save_issue"), "the label should come from the chat's function")
    }

    private static func snippetPrefersNarrationOnOneLine() {
        var session = TrackerSession(id: "a", title: "A", repoName: "R", agent: "codex", role: "master", snippet: "Bash: npm test")
        expect(TrackerRowText.snippet(for: session) == "Bash: npm test", "without narration the snippet is the latest activity")
        session.narration = "It seems that\n\nsomething   is still failing."
        expect(TrackerRowText.snippet(for: session) == "It seems that something is still failing.", "narration shows on one line, got \(TrackerRowText.snippet(for: session))")
        session.narration = String(repeating: "a", count: 200)
        expect(TrackerRowText.snippet(for: session).count == 180, "long narration is capped like the snippet")
        session.agent = "shell"
        expect(TrackerRowText.snippet(for: session).isEmpty, "a shell shows no snippet")
    }

    private static func portraitRingMirrorsTheCast() {
        let bash = TrackerCast(tool: "Bash", startedAt: Date(), typicalMS: 6000)
        let mcp = TrackerCast(tool: "mcp__linear__save_issue", startedAt: Date(), typicalMS: 0)
        expect(TrackerPortraitRing.ring(status: .working, cast: bash) == .filling(bash), "a working tool with a learned duration fills the ring")
        expect(TrackerPortraitRing.ring(status: .working, cast: mcp) == .spinning(mcp), "a tool with no learned duration spins the ring")
        expect(TrackerPortraitRing.ring(status: .working, cast: nil) == .spinning(nil), "working with no tool spins the ring")
        for status in [TrackerStatusKind.blocked, .needsInput, .error] {
            expect(TrackerPortraitRing.ring(status: status, cast: bash) == .steady, "\(status) shows a still ring, cast or not")
        }
        for status in [TrackerStatusKind.done, .idle, .stopped] {
            expect(TrackerPortraitRing.ring(status: status, cast: nil) == .none, "\(status) shows no ring")
        }
        expect(TrackerPortraitRing.filling(bash).cast == bash && TrackerPortraitRing.spinning(mcp).cast == mcp, "the ring carries its cast")
        expect(TrackerPortraitRing.spinning(nil).cast == nil && TrackerPortraitRing.steady.cast == nil, "a ring with no tool carries no cast")
        expect(TrackerPortraitRing.spinning(nil).isWorking && TrackerPortraitRing.filling(bash).isWorking, "filling and spinning are working rings")
        expect(!TrackerPortraitRing.steady.isWorking && !TrackerPortraitRing.none.isWorking, "steady and no ring are not")
    }

    private static func sameCallIgnoresTheLearnedDuration() {
        let started = Date(timeIntervalSince1970: 100)
        let bash = TrackerCast(tool: "Bash", startedAt: started, typicalMS: 6000)
        expect(bash.isSameCall(as: TrackerCast(tool: "Bash", startedAt: started, typicalMS: 9000)), "a new typical is the same call")
        expect(TrackerCast(tool: "Bash", startedAt: started, typicalMS: 0).isSameCall(as: bash), "a duration learned mid-call is the same call")
        expect(!bash.isSameCall(as: TrackerCast(tool: "Bash", startedAt: started.addingTimeInterval(1), typicalMS: 6000)), "a new start is a new call")
        expect(!bash.isSameCall(as: TrackerCast(tool: "Read", startedAt: started, typicalMS: 6000)), "a new tool is a new call")
        expect(!bash.isSameCall(as: nil), "no cast is not the same call")
    }

    private static func barHoldsItsFinishWhileTheRowCloses() {
        let bash = TrackerCast(tool: "Bash", startedAt: Date(timeIntervalSince1970: 100), typicalMS: 6000)
        let finishing = TrackerCastPhase.casting(bash).next(cast: nil, status: .working)
        let finishBar = TrackerCastPhase.bar(after: finishing, holding: nil)
        expect(finishBar == TrackerCastBar(cast: bash, isFinishing: true), "an ended cast's bar shows the finish")
        let blocked = finishing.next(cast: nil, status: .blocked)
        expect(blocked == .hidden, "going blocked during the finish hides the row")
        expect(TrackerCastPhase.bar(after: blocked, holding: finishBar) == finishBar, "the closing row keeps the finish, not a fill")
        expect(TrackerCastPhase.bar(after: .casting(bash), holding: finishBar) == TrackerCastBar(cast: bash, isFinishing: false), "a cast replaces the held bar")
    }

    private static func symbolsCoverEachAgentsTools() {
        let table: [(String, String)] = [
            ("Bash", "terminal"), ("exec_command", "terminal"), ("local_shell", "terminal"), ("shell", "terminal"),
            ("Edit", "pencil"), ("MultiEdit", "pencil"), ("apply_patch", "pencil"), ("patch", "pencil"),
            ("Read", "doc.text.magnifyingglass"), ("Grep", "doc.text.magnifyingglass"), ("list", "doc.text.magnifyingglass"), ("find", "doc.text.magnifyingglass"),
            ("WebFetch", "globe"), ("web_search", "globe"),
            ("Task", "person.2"), ("Agent", "person.2"),
            ("TodoWrite", "checklist"), ("todoread", "checklist"), ("update_plan", "checklist"),
            ("mcp__linear__save_issue", "puzzlepiece.extension"),
        ]
        for (tool, symbol) in table {
            let got = TrackerCast(tool: tool, startedAt: Date(), typicalMS: 0).symbol
            expect(got == symbol, "\(tool) should show \(symbol), got \(got)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("TrackerCastTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
