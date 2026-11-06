import Foundation
import QuestmasterCore

struct TmuxRouteTests {
    static func run() throws {
        let fixture = try fixtureData()
        let routes = try TmuxRoute.decodeResponse(fixture)
        try expect(routes.count == 1, "fixture should contain one route")
        let legacy = routes[0]
        try expect(legacy.sessionID == "qm-example" && legacy.label == "default" && legacy.live, "legacy fixture should decode")
        try expect(legacy.arguments(for: ["list-clients"]) == ["-L", "default", "list-clients"], "legacy argv should name its server")

        let named = try TmuxRoute(sessionID: "qm-named", label: "questmaster_dev", configFiles: ["/tmp/user's config.conf", "/tmp/enforced.conf"], live: true, createdUnix: 200)
        try expect(named.arguments(for: ["has-session", "-t", "=qm-named"]) == ["-L", "questmaster_dev", "-f", "/tmp/user's config.conf", "-f", "/tmp/enforced.conf", "has-session", "-t", "=qm-named"], "named argv should preserve separate config paths")
        for label in ["", "../other", "UPPER", "name with space", "name;true", String(repeating: "a", count: 33)] {
            try expect((try? TmuxRoute(sessionID: "qm-x", label: label, configFiles: [], live: true, createdUnix: 1)) == nil, "invalid label should fail: \(label)")
        }
        try expect((try? TmuxRoute(sessionID: "qm-x", label: "questmaster", configFiles: ["relative.conf"], live: true, createdUnix: 1)) == nil, "relative config path should fail")

        try expect(TmuxRoute.surfaceDecision(attachedLabel: "default", targetLabel: "default", clientAttached: true, sessionReappeared: false) == .reuseClient, "same server should reuse an attached client")
        try expect(TmuxRoute.surfaceDecision(attachedLabel: "default", targetLabel: "questmaster", clientAttached: true, sessionReappeared: false) == .newSurface, "cross-server switch needs a new surface")
        try expect(TmuxRoute.surfaceDecision(attachedLabel: "default", targetLabel: "default", clientAttached: true, sessionReappeared: true) == .newSurface, "a reappeared session needs a new surface")
        try expect(TmuxRoute.surfaceDecision(attachedLabel: "default", targetLabel: "default", clientAttached: false, sessionReappeared: false) == .newSurface, "detached client needs a new surface")
        let stopped = try TmuxRoute(sessionID: "qm-stopped", label: "default", configFiles: [], live: false, createdUnix: legacy.createdUnix + 2)
        let newest = try TmuxRoute(sessionID: "qm-new", label: "questmaster", configFiles: ["/tmp/config.conf"], live: true, createdUnix: legacy.createdUnix + 1)
        try expect(TmuxRoute.startupChoice(preferred: legacy.sessionID, routes: [stopped, newest, legacy]) == legacy, "startup should keep a live preference")
        try expect(TmuxRoute.startupChoice(preferred: stopped.sessionID, routes: [stopped, newest, legacy]) == newest, "startup should choose newest live route across servers")
        print("TmuxRouteTests: all tests passed")
    }

    private static func fixtureData() throws -> Data {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let path = url.appendingPathComponent("internal/serve/testdata/tmux_routes_response_envelope.json")
            if FileManager.default.fileExists(atPath: path.path) { return try Data(contentsOf: path) }
            url.deleteLastPathComponent()
        }
        throw Failure("tmux routes fixture missing")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
