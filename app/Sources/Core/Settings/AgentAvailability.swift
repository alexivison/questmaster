import Foundation

public struct AgentAvailability: Decodable, Equatable {
    public struct RoleDefault: Decodable, Equatable {
        public let model: String
        public let reasoningEffort: String

        public init(model: String, reasoningEffort: String) {
            self.model = model
            self.reasoningEffort = reasoningEffort
        }

        private enum CodingKeys: String, CodingKey {
            case model
            case reasoningEffort = "reasoning_effort"
        }
    }

    public struct Entry: Decodable, Equatable {
        public let name: String
        public let enabled: Bool
        public let defaults: [String: RoleDefault]

        public init(name: String, enabled: Bool, defaults: [String: RoleDefault] = [:]) {
            self.name = name
            self.enabled = enabled
            self.defaults = defaults
        }
    }

    public let agents: [Entry]

    public init(agents: [Entry]) {
        self.agents = agents
    }

    public var enabledNames: [String] {
        agents.filter(\.enabled).map(\.name)
    }

    /// Returns a copy with one agent's enabled flag changed while preserving
    /// its saved role defaults and the daemon's agent order.
    public func updatingEnabled(_ enabled: Bool, for agent: String) -> AgentAvailability? {
        guard let index = agents.firstIndex(where: { $0.name == agent }) else {
            return nil
        }
        var updated = agents
        let current = updated[index]
        updated[index] = Entry(name: current.name, enabled: enabled, defaults: current.defaults)
        return AgentAvailability(agents: updated)
    }
}
