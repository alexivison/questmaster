import Foundation
import QuestmasterCore

/// Tracker sessions decoded from the payload's JSON, for the class avatar's tests.
enum AvatarSessionFixture {
    static func session(
        id: String = "qm-1",
        agent: String = "claude",
        sessionClass: String? = "bard",
        state: String = "working",
        status: String = "active",
        parentID: String = "",
        tool: String? = nil,
        exchange: (kind: String, at: String)? = nil,
        elapsedSince: String? = nil,
        activeSubagents: Int = 0,
        activity: String? = nil
    ) -> TrackerSession {
        var fields: [String: Any] = [
            "id": id,
            "title": id,
            "status": status,
            "state": state,
            "agent": agent,
            "parent_id": parentID,
            "worker_count": 0,
            "elapsed_ms": 0,
        ]
        if let sessionClass {
            fields["class"] = sessionClass
        }
        if let tool {
            fields["cast"] = ["tool": tool, "started_at": "2026-10-28T09:00:00Z", "typical_ms": 0]
        }
        if let exchange {
            fields["last_exchange"] = ["kind": exchange.kind, "at": exchange.at]
        }
        if let elapsedSince {
            fields["elapsed_since"] = elapsedSince
        }
        fields["active_subagents"] = activeSubagents
        if let activity {
            fields["latest_activity"] = activity
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
              let session = try? JSONDecoder().decode(TrackerSession.self, from: data) else {
            fputs("AvatarSessionFixture: a session should decode\n", stderr)
            exit(1)
        }
        return session
    }
}
