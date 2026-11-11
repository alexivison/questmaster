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
        var cache = TmuxRouteCache()
        try expect(cache.lookup("qm-example") == .fetch, "cache miss should wait for a route fetch")
        cache.remember([legacy])
        try expect(cache.lookup("qm-example") == .cached(legacy), "cache hit should attach immediately")
        switch cache.resolve(for: legacy.sessionID, result: .failure(TmuxRouteError.invalidResponse)) {
        case .success(let route): try expect(route == legacy, "fetch failure should retain a cached route")
        case .failure: throw Failure("cached route should survive a fetch failure")
        }
        switch cache.resolve(for: "qm-missing", result: .failure(TmuxRouteError.invalidResponse)) {
        case .success: throw Failure("uncached fetch failure should fail")
        case .failure: break
        }
        let moved = try TmuxRoute(sessionID: legacy.sessionID, label: "questmaster", configFiles: ["/tmp/config.conf"], live: true, createdUnix: legacy.createdUnix)
        try expect(TmuxRoute.replacement(for: legacy, in: [named, moved]) == moved,
                   "a failed attach may retry only the changed route for its own session")
        try expect(TmuxRoute.replacement(for: legacy, in: [named, legacy]) == nil,
                   "the same route does not justify a retry")
        try expect(TmuxRoute.replacement(for: legacy, in: [named]) == nil,
                   "another session's route cannot be used for an attach")
        switch cache.resolve(for: legacy.sessionID, result: .success([moved])) {
        case .success(let route): try expect(route == moved, "fetch should return the new route")
        case .failure: throw Failure("route change should resolve")
        }
        try expect(cache.lookup(legacy.sessionID) == .cached(moved), "route change should replace the cached route")
        cache.invalidate(legacy.sessionID)
        try expect(cache.lookup(legacy.sessionID) == .fetch, "reappearing session must discard its old route")
        cache.remember([legacy])
        switch cache.resolve(for: legacy.sessionID, result: .failure(TmuxRouteError.invalidResponse), useCachedRouteOnFailure: false) {
        case .success: throw Failure("a reappearing session must not use a cached route after a failed fetch")
        case .failure: break
        }
        if case .unknownMethod(let method) = ServeClientError.responseError("unknown method \"tmux.routes\"") {
            try expect(method == "tmux.routes", "unknown method should keep its name")
        } else {
            throw Failure("known backend error should decode as unknownMethod")
        }
        if case .protocolError = ServeClientError.responseError("unknown method tmux.routes") {
            // A different message does not claim to be the backend's known format.
        } else {
            throw Failure("unrecognized backend error should stay a protocol error")
        }
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
