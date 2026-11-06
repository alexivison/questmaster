import Foundation

public struct TmuxRouteCache {
    public enum Lookup: Equatable {
        case cached(TmuxRoute)
        case fetch
    }

    private static let maxEntries = 128
    private var routes: [String: TmuxRoute] = [:]
    private var order: [String] = []

    public init() {}

    public func lookup(_ sessionID: String) -> Lookup {
        routes[sessionID].map(Lookup.cached) ?? .fetch
    }

    public mutating func remember(_ fetched: [TmuxRoute]) {
        for route in fetched {
            routes[route.sessionID] = route
            order.removeAll { $0 == route.sessionID }
            order.append(route.sessionID)
            if order.count > Self.maxEntries {
                routes.removeValue(forKey: order.removeFirst())
            }
        }
    }

    public mutating func resolve(for sessionID: String, result: Result<[TmuxRoute], Error>) -> Result<TmuxRoute, Error> {
        switch result {
        case .success(let fetched):
            remember(fetched)
            guard let route = fetched.first(where: { $0.sessionID == sessionID }) else {
                return .failure(TmuxRouteError.missingSession(sessionID))
            }
            return .success(route)
        case .failure(let error):
            if let route = routes[sessionID] { return .success(route) }
            return .failure(error)
        }
    }
}
