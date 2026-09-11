import Foundation

/// One Settings row: the persisted default model and reasoning effort for one
/// agent+role pair. Reuses `SessionModelOption`/`SessionReasoningEffortOption`
/// from the New Session sheet — the "default" entry (empty id) means the same
/// thing here as there: no override, the harness's own default applies.
public struct RoleDefaultRow: Equatable {
    public let agent: String
    public let role: String // "worker" or "master"

    public private(set) var modelOptions: [SessionModelOption]
    public private(set) var selectedModelIndex: Int
    public private(set) var effortOptions: [SessionReasoningEffortOption]
    public private(set) var selectedEffortIndex: Int
    /// False until `setModelOptions`/`setEffortOptions` first resolves this
    /// row's real list — the sheet shows a skeleton in place of the select
    /// control until then, rather than the placeholder "default" entry.
    public private(set) var hasResolvedModelOptions = false
    public private(set) var hasResolvedEffortOptions = false

    public init(agent: String, role: String) {
        self.agent = agent
        self.role = role
        modelOptions = [.defaultOption()]
        selectedModelIndex = 0
        effortOptions = [.defaultOption()]
        selectedEffortIndex = 0
    }

    public var selectedModelOption: SessionModelOption {
        modelOptions.indices.contains(selectedModelIndex) ? modelOptions[selectedModelIndex] : .defaultOption()
    }

    /// The selected model id, empty when the default entry is selected —
    /// what `role_default.set` sends to clear the override.
    public var selectedModel: String {
        selectedModelOption.isDefault ? "" : selectedModelOption.id
    }

    public var selectedEffortOption: SessionReasoningEffortOption {
        effortOptions.indices.contains(selectedEffortIndex) ? effortOptions[selectedEffortIndex] : .defaultOption()
    }

    /// The selected reasoning-effort level, empty when the default entry is
    /// selected.
    public var selectedReasoningEffort: String {
        selectedEffortOption.isDefault ? "" : selectedEffortOption.id
    }

    /// Replaces the model list with what the backend resolved for this row's
    /// agent and role. A selection already made survives the refresh when the
    /// new list still offers it. Mirrors `NewSessionFormModel.setModelOptions`.
    public mutating func setModelOptions(_ models: [SessionModelOption], defaultModel: String) {
        let previous = selectedModel
        var options: [SessionModelOption] = [.defaultOption(note: defaultModel)]
        for model in models where !model.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            options.append(model)
        }
        modelOptions = options
        selectedModelIndex = options.firstIndex(where: { $0.id == previous }) ?? 0
        hasResolvedModelOptions = true
    }

    /// Replaces the reasoning-effort list with what the backend resolved for
    /// this row's agent, role and currently selected model. Mirrors
    /// `NewSessionFormModel.setEffortOptions`.
    public mutating func setEffortOptions(_ levels: [String], defaultLevel: String) {
        let previous = selectedReasoningEffort
        var options: [SessionReasoningEffortOption] = [.defaultOption(defaultLevel)]
        for level in levels {
            let trimmed = level.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != defaultLevel else {
                continue
            }
            options.append(SessionReasoningEffortOption(id: trimmed, label: trimmed))
        }
        effortOptions = options
        selectedEffortIndex = options.firstIndex(where: { $0.id == previous }) ?? 0
        hasResolvedEffortOptions = true
    }

    public mutating func cycleModel(_ delta: Int) {
        selectedModelIndex = roleDefaultsWrapped(selectedModelIndex + delta, count: modelOptions.count)
    }

    public mutating func cycleEffort(_ delta: Int) {
        selectedEffortIndex = roleDefaultsWrapped(selectedEffortIndex + delta, count: effortOptions.count)
    }
}

/// The two independently-selectable controls within one `RoleDefaultRow`.
public enum RoleDefaultField: Equatable {
    case model
    case effort
}

/// Backs the Settings sheet's default-model/reasoning-effort table: one tab
/// per agent, each showing that agent's Master and Worker rows, each with two
/// independently focusable/cyclable controls (model, effort).
public struct RoleDefaultsSettingsModel: Equatable {
    public static let defaultAgents = NewSessionFormModel.defaultAgents
    public static let roles = ["master", "worker"]

    public let agents: [String]
    public private(set) var rows: [RoleDefaultRow]
    public var selectedAgentIndex: Int
    /// Index into `Self.roles` for the currently focused row within the
    /// active tab.
    public var focusedRoleIndex: Int
    public var focusedField: RoleDefaultField

    public init(agents: [String] = RoleDefaultsSettingsModel.defaultAgents) {
        let resolvedAgents = agents.isEmpty ? RoleDefaultsSettingsModel.defaultAgents : agents
        self.agents = resolvedAgents
        rows = resolvedAgents.flatMap { agent in
            Self.roles.map { role in RoleDefaultRow(agent: agent, role: role) }
        }
        selectedAgentIndex = 0
        focusedRoleIndex = 0
        focusedField = .model
    }

    public var selectedAgent: String {
        agents[selectedAgentIndex]
    }

    /// The row index within `rows` for the currently focused (tab, role)
    /// combination.
    public var focusedRowIndex: Int? {
        index(agent: selectedAgent, role: Self.roles[focusedRoleIndex])
    }

    public func index(agent: String, role: String) -> Int? {
        rows.firstIndex { $0.agent == agent && $0.role == role }
    }

    public mutating func setModelOptions(_ models: [SessionModelOption], defaultModel: String, agent: String, role: String) {
        guard let index = index(agent: agent, role: role) else {
            return
        }
        rows[index].setModelOptions(models, defaultModel: defaultModel)
    }

    public mutating func setEffortOptions(_ levels: [String], defaultLevel: String, agent: String, role: String) {
        guard let index = index(agent: agent, role: role) else {
            return
        }
        rows[index].setEffortOptions(levels, defaultLevel: defaultLevel)
    }

    /// Moves focus by `delta` steps across the active tab's 4 fields (master
    /// model, master effort, worker model, worker effort) — wraps within the
    /// tab. Switching tabs is `moveTab`'s job, not this one's.
    public mutating func moveFocus(_ delta: Int) {
        let totalFields = Self.roles.count * 2
        let current = focusedRoleIndex * 2 + (focusedField == .model ? 0 : 1)
        let next = roleDefaultsWrapped(current + delta, count: totalFields)
        focusedRoleIndex = next / 2
        focusedField = next.isMultiple(of: 2) ? .model : .effort
    }

    /// Jumps directly to a specific agent tab (e.g. a mouse click) and resets
    /// focus to that tab's first field.
    public mutating func selectTab(_ index: Int) {
        guard agents.indices.contains(index) else {
            return
        }
        selectedAgentIndex = index
        focusedRoleIndex = 0
        focusedField = .model
    }

    /// Switches the active agent tab by `delta` steps, wrapping.
    public mutating func moveTab(_ delta: Int) {
        guard !agents.isEmpty else {
            return
        }
        selectTab(roleDefaultsWrapped(selectedAgentIndex + delta, count: agents.count))
    }

    /// Cycles the value of whichever field currently has focus.
    public mutating func cycleFocusedValue(_ delta: Int) {
        guard let rowIndex = focusedRowIndex else {
            return
        }
        switch focusedField {
        case .model:
            rows[rowIndex].cycleModel(delta)
        case .effort:
            rows[rowIndex].cycleEffort(delta)
        }
    }
}

private func roleDefaultsWrapped(_ index: Int, count: Int) -> Int {
    guard count > 0 else {
        return 0
    }
    if index < 0 {
        return count - 1
    }
    if index >= count {
        return 0
    }
    return index
}
