import Foundation

/// One Settings row: the persisted default model and reasoning effort for one
/// agent+role pair. Reuses `SessionModelOption`/`SessionReasoningEffortOption`
/// from the New Session sheet. Unlike New Session, "not configured" here is a
/// one-way door: a row that starts unconfigured can be given a real value, but
/// a row that already has one can never be cycled back to unconfigured —
/// Settings is the sole source of a default, and the persisted store itself
/// rejects an attempt to clear an existing entry (see
/// `role_default.set`/`RoleDefaultsStore.Set`).
public struct RoleDefaultRow: Equatable {
    public let agent: String
    public let role: String // "master", "standalone" or "worker"

    public private(set) var modelOptions: [SessionModelOption]
    public private(set) var selectedModelIndex: Int?
    public private(set) var effortOptions: [SessionReasoningEffortOption]
    public private(set) var selectedEffortIndex: Int?
    /// False until `setModelOptions`/`setEffortOptions` first resolves this
    /// row's real list — the sheet shows a skeleton in place of the select
    /// control until then.
    public private(set) var hasResolvedModelOptions = false
    public private(set) var hasResolvedEffortOptions = false

    /// Set once, at first resolve: whether "not configured" is still a
    /// reachable cycle position for this field. False the moment a persisted
    /// default is found — there is no going back to unconfigured from there.
    private var canReturnToNotConfiguredModel = true
    private var canReturnToNotConfiguredEffort = true
    /// The selection as of the last successful save (or the first resolve,
    /// before anything is saved) — `isDirty` diffs the live selection against
    /// this baseline so `confirm()` only resends rows that actually changed.
    private var savedModelIndexAtResolve: Int?
    private var savedEffortIndexAtResolve: Int?

    public init(agent: String, role: String) {
        self.agent = agent
        self.role = role
        modelOptions = []
        selectedModelIndex = nil
        effortOptions = []
        selectedEffortIndex = nil
    }

    public var selectedModelOption: SessionModelOption? {
        selectedModelIndex.flatMap { roleDefaultsValue(at: $0, in: modelOptions) }
    }

    /// The selected model id, empty when nothing is selected.
    public var selectedModel: String {
        selectedModelOption?.id ?? ""
    }

    public var selectedEffortOption: SessionReasoningEffortOption? {
        selectedEffortIndex.flatMap { roleDefaultsValue(at: $0, in: effortOptions) }
    }

    /// The selected reasoning-effort level, empty when nothing is selected.
    public var selectedReasoningEffort: String {
        selectedEffortOption?.id ?? ""
    }

    /// Whether the model selection has changed since it was last saved (or
    /// since the row's first resolve, if never saved).
    public var isModelDirty: Bool {
        hasResolvedModelOptions && selectedModelIndex != savedModelIndexAtResolve
    }

    /// Whether the effort selection has changed since it was last saved (or
    /// since the row's first resolve, if never saved).
    public var isEffortDirty: Bool {
        hasResolvedEffortOptions && selectedEffortIndex != savedEffortIndexAtResolve
    }

    /// Whether this row has any unsaved change — `confirm()` only sends rows
    /// where this is true, so an untouched row (configured or not) is never
    /// resent and can never be silently cleared or recreated.
    public var isDirty: Bool {
        isModelDirty || isEffortDirty
    }

    /// Replaces the model list with what the backend resolved for this row's
    /// agent and role. On the very first resolve, the selection seeds onto
    /// `defaultModel` (the persisted override, if any) directly — the value
    /// shown in the picker IS the default, with no separate placeholder
    /// entry. A later re-resolve (e.g. after the user changes the model and
    /// the effort list refetches) preserves whatever is currently selected
    /// instead, so an in-progress edit never gets discarded.
    public mutating func setModelOptions(_ models: [SessionModelOption], defaultModel: String) {
        let firstResolve = !hasResolvedModelOptions
        let previousID = selectedModelOption?.id
        modelOptions = models.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if firstResolve {
            let foundIndex = defaultModel.isEmpty ? nil : modelOptions.firstIndex(where: { $0.id == defaultModel })
            // Gate on whether a default was actually found and selected, not
            // just on whether the backend reported a non-empty string: if a
            // persisted default's id is somehow missing from the resolved
            // list, the row still displays (and behaves) as unconfigured
            // rather than getting silently locked out of "not configured".
            selectedModelIndex = foundIndex
            canReturnToNotConfiguredModel = foundIndex == nil
            savedModelIndexAtResolve = selectedModelIndex
        } else {
            selectedModelIndex = previousID.flatMap { id in modelOptions.firstIndex(where: { $0.id == id }) }
        }
        hasResolvedModelOptions = true
    }

    /// Replaces the reasoning-effort list with what the backend resolved for
    /// this row's agent, role and currently selected model. Mirrors
    /// `setModelOptions`'s first-resolve seeding.
    public mutating func setEffortOptions(_ levels: [String], defaultLevel: String) {
        let firstResolve = !hasResolvedEffortOptions
        let previousID = selectedEffortOption?.id
        effortOptions = levels.compactMap { level in
            let trimmed = level.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : SessionReasoningEffortOption(id: trimmed, label: trimmed)
        }
        if firstResolve {
            let foundIndex = defaultLevel.isEmpty ? nil : effortOptions.firstIndex(where: { $0.id == defaultLevel })
            selectedEffortIndex = foundIndex
            canReturnToNotConfiguredEffort = foundIndex == nil
            savedEffortIndexAtResolve = selectedEffortIndex
        } else {
            selectedEffortIndex = previousID.flatMap { id in effortOptions.firstIndex(where: { $0.id == id }) }
        }
        hasResolvedEffortOptions = true
    }

    public mutating func cycleModel(_ delta: Int) {
        selectedModelIndex = roleDefaultsCycleOptional(
            selectedModelIndex, delta: delta, count: modelOptions.count, canReturnToNotConfigured: canReturnToNotConfiguredModel
        )
    }

    public mutating func cycleEffort(_ delta: Int) {
        selectedEffortIndex = roleDefaultsCycleOptional(
            selectedEffortIndex, delta: delta, count: effortOptions.count, canReturnToNotConfigured: canReturnToNotConfiguredEffort
        )
    }

    /// Marks the values actually persisted by a `role_default.set` save as
    /// the new saved baseline. Takes the values that were sent — not the
    /// row's current live selection — because the user can keep editing
    /// while that save is still in flight; baselining the live selection
    /// would silently mark a newer, never-sent edit as "already saved" the
    /// instant the earlier save's ack arrives.
    public mutating func markSaved(model: String, reasoningEffort: String) {
        savedModelIndexAtResolve = model.isEmpty ? nil : modelOptions.firstIndex(where: { $0.id == model })
        savedEffortIndexAtResolve = reasoningEffort.isEmpty ? nil : effortOptions.firstIndex(where: { $0.id == reasoningEffort })
    }
}

/// The two independently-selectable controls within one `RoleDefaultRow`.
public enum RoleDefaultField: Equatable {
    case model
    case effort
}

/// Backs the Settings sheet's default-model/reasoning-effort table: one tab
/// per agent, each showing that agent's Master, Standalone and Worker rows,
/// each with two independently focusable/cyclable controls (model, effort).
public struct RoleDefaultsSettingsModel: Equatable {
    public static let defaultAgents = NewSessionFormModel.defaultAgents
    public static let roles = ["master", "standalone", "worker"]

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

    /// Marks the values actually persisted by one row's `role_default.set`
    /// save as its new saved baseline — call once that save actually lands.
    public mutating func markSaved(agent: String, role: String, model: String, reasoningEffort: String) {
        guard let index = index(agent: agent, role: role) else {
            return
        }
        rows[index].markSaved(model: model, reasoningEffort: reasoningEffort)
    }

    /// Moves focus by `delta` steps across the active tab's fields (model and
    /// effort for each role in `roles`, in order) — wraps within the tab.
    /// Switching tabs is `moveTab`'s job, not this one's.
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

private func roleDefaultsValue<T>(at index: Int, in values: [T]) -> T? {
    guard values.indices.contains(index) else {
        return nil
    }
    return values[index]
}

/// Cycles among `count` real options plus, only when `canReturnToNotConfigured`
/// is true, a virtual "not configured" slot at the end, wrapping. Once a row
/// starts with a persisted override, `canReturnToNotConfigured` is false and
/// the virtual slot is entirely absent from the cycle — there is no way to
/// pick a real value and then cycle back to "not configured" for that row.
private func roleDefaultsCycleOptional(_ current: Int?, delta: Int, count: Int, canReturnToNotConfigured: Bool) -> Int? {
    let slots = count + (canReturnToNotConfigured ? 1 : 0)
    guard slots > 0 else {
        return nil
    }
    let currentSlot = current ?? count
    let next = roleDefaultsWrapped(currentSlot + delta, count: slots)
    return next < count ? next : nil
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
