import Foundation
import QuestmasterCore

struct TrackerCastTests {
    static func run() {
        castAndNarrationDecodeFromASession()
        missingCastAndNarrationDecodeAsNone()
        unknownTypicalDurationShimmers()
        fillReachesNinetyAtTypicalAndHoldsShortOfFull()
        keyframesRunFromNowToTheHold()
        keyframesPastTypicalOnlyCreep()
        phaseOpensFinishesAndReplaces()
        labelIsTheChatsCallLabel()
        snippetPrefersNarrationOnOneLine()
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

    private static func fillReachesNinetyAtTypicalAndHoldsShortOfFull() {
        let typical = 6.0
        expect(TrackerCastFill.fraction(elapsed: 0, typical: typical) == 0, "the bar starts empty")
        expect(TrackerCastFill.fraction(elapsed: -2, typical: typical) == 0, "a start in the future reads as empty")
        expect(abs(TrackerCastFill.fraction(elapsed: 3, typical: typical) - 0.45) < 1e-9, "halfway to the typical time is 45%")
        expect(abs(TrackerCastFill.fraction(elapsed: typical, typical: typical) - 0.9) < 1e-9, "the typical time is 90%")
        let past = TrackerCastFill.fraction(elapsed: 2 * typical, typical: typical)
        expect(past > 0.9 && past < 0.95, "past the typical time the bar creeps on, got \(past)")
        let long = TrackerCastFill.fraction(elapsed: 10 * typical, typical: typical)
        expect(long < 0.95 && long > 0.949, "a long run holds just short of 95%, got \(long)")
    }

    private static func keyframesRunFromNowToTheHold() {
        let frames = TrackerCastFill.keyframes(elapsed: 2, typical: 6)
        expect(frames.first?.offset == 0, "the path starts now")
        expect(abs((frames.first?.fraction ?? 0) - 0.3) < 1e-9, "the path starts at the current fraction")
        expect(abs(frames[1].offset - 4) < 1e-9 && abs(frames[1].fraction - 0.9) < 1e-9, "90% lands at the typical time, 4s from now")
        expect(zip(frames, frames.dropFirst()).allSatisfy { $0.offset < $1.offset && $0.fraction <= $1.fraction }, "the path only moves forward")
        expect(frames.count == 2 + TrackerCastFill.creepSamples, "the creep is sampled after the 90% mark")
        let hold = frames.last?.fraction ?? 0
        expect(hold > 0.94 && hold < 0.95, "the path ends at the hold, got \(hold)")
    }

    private static func keyframesPastTypicalOnlyCreep() {
        let frames = TrackerCastFill.keyframes(elapsed: 9, typical: 6)
        expect(abs((frames.first?.fraction ?? 0) - TrackerCastFill.fraction(elapsed: 9, typical: 6)) < 1e-9, "a late start resumes the creep where it is")
        expect(frames.count == 1 + TrackerCastFill.creepSamples, "past the typical time there is no 90% mark to reach")
        let ended = TrackerCastFill.keyframes(elapsed: 60, typical: 6)
        expect(ended.count == 1, "past the creep's span the bar only holds")
    }

    private static func phaseOpensFinishesAndReplaces() {
        let bash = TrackerCast(tool: "Bash", startedAt: Date(timeIntervalSince1970: 100), typicalMS: 6000)
        let edit = TrackerCast(tool: "Edit", startedAt: Date(timeIntervalSince1970: 200), typicalMS: 1000)
        let hidden = TrackerCastPhase.hidden
        expect(hidden.next(cast: nil) == .hidden, "with no cast the row stays hidden")
        expect(hidden.next(cast: bash) == .casting(bash), "a cast opens the row")
        expect(TrackerCastPhase.casting(bash).next(cast: nil) == .finishing(bash), "an ended cast finishes")
        expect(TrackerCastPhase.finishing(bash).next(cast: nil) == .finishing(bash), "a finishing row waits for its own end")
        expect(TrackerCastPhase.finishing(bash).next(cast: edit) == .casting(edit), "a new cast replaces a finishing one at once")
        expect(TrackerCastPhase.casting(bash).next(cast: edit) == .casting(edit), "the latest cast replaces the running one")
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
