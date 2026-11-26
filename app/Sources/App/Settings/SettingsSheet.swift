import AppKit
import Combine
import QuestmasterCore
import SwiftUI

@MainActor
final class SettingsSheetPresenter: ObservableObject {
    @Published var presentation: SettingsSheetPresentation?

    func present(
        mutationClient: ServeMutationSending,
        modelClient: ServeModelSuggesting?,
        effortClient: ServeReasoningEffortSuggesting?,
        runtime: RuntimeStore,
        openTmuxConfig: @escaping TmuxSettingsPageModel.EditorOpening = { _, completion in completion(.failure(ArtifactExternalOpenError.missingSession)) }
    ) {
        presentation = SettingsSheetPresentation(
            mutationClient: mutationClient,
            modelClient: modelClient,
            effortClient: effortClient,
            runtime: runtime,
            openTmuxConfig: openTmuxConfig
        )
    }

    func dismiss() {
        presentation = nil
    }
}

struct SettingsSheetPresentation: Identifiable {
    let id = UUID()
    let mutationClient: ServeMutationSending
    let modelClient: ServeModelSuggesting?
    let effortClient: ServeReasoningEffortSuggesting?
    /// The projects the Projects section lists, and where its rows follow each snapshot.
    let runtime: RuntimeStore
    var openTmuxConfig: TmuxSettingsPageModel.EditorOpening = { _, completion in completion(.failure(ArtifactExternalOpenError.missingSession)) }
}

/// settings-models.svg (900 x 780): the sections as pill tabs down the left (250 wide), and the selected
/// section on the right (x 290-880): the agent tabs and availability switch, then a "Master" and a "Worker"
/// section, each a bold title over a vine-ended rule and separate searchable model and reasoning fields.
enum SettingsMetrics {
    static let inset = PanelMetrics.contentInset
    static let sidebarWidth: CGFloat = 250
    static let columnSpacing = Space.section
    static let columnWidth = SettingsSheetModel.sheetSize.width - 2 * inset - sidebarWidth - columnSpacing
    static let sidebarSpacing = Space.section
    /// A section's glyph fills its tab's 20pt icon square. The keylined brain, folder and terminal measure 15 x 15, 15 x 14
    /// and 15 x 13 there, against the SF symbols' 15.6 x 15, 16.3 x 13.2 and 16.0 x 12.5 that the tab fitted into that square.
    static let sectionIconSide: CGFloat = PillTabMetrics.iconSide
    /// The availability row follows the agent tabs by one section gap.
    static let availabilityOffset = PillTabMetrics.rowHeight + Space.section
    static let availabilityHeight = ControlHeight.field + Space.row
    /// The first role section follows the availability row by one group gap.
    static let firstSectionBaseline = availabilityOffset + availabilityHeight + Space.group
    /// Each role section title sits 175 below the previous one.
    static let sectionPitch: CGFloat = 175
    /// From a section title's baseline: its rule, then each row's picker top, 55 apart (a field and the 20 between).
    static let ruleDrop: CGFloat = 15
    static let firstRowDrop: CGFloat = 35
    static let rowPitch = pickerHeight + Space.section
    static let labelWidth: CGFloat = 150
    static let labelBaseline = FormFieldMetrics.baseline
    static let pickerHeight = ControlHeight.field
    /// The ghost of the picker's value, and the opacities the whole ghost breathes between.
    static let skeletonValueWidth: CGFloat = 40
    static let skeletonPulseFrom = 0.5
    static let skeletonPulseTo = 0.7
}

/// The sidebar's sections. Only the ones that exist are listed; a new one is a new case.
enum SettingsSection: CaseIterable {
    case modelsAndReasoning
    case projects
    case tmux

    var title: String {
        switch self {
        case .modelsAndReasoning:
            return "Models and Reasoning"
        case .projects:
            return "Projects"
        case .tmux:
            return "Tmux"
        }
    }

    /// The tab's decided icon: the Projects folder, and the tmux tab's shell disc.
    var icon: AppIcon {
        switch self {
        case .modelsAndReasoning:
            return .settingsModelsBrain
        case .projects:
            return .settingsProjectsFolder
        case .tmux:
            return .discShellTerminal
        }
    }
}

struct SettingsSheetView: View {
    @StateObject private var model: SettingsSheetModel

    /// Role groups shown for the active tab, top-to-bottom.
    private static let roleGroups = [("master", "Master"), ("worker", "Worker")]

    init(presentation: SettingsSheetPresentation, dismiss: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SettingsSheetModel(presentation: presentation, dismiss: dismiss))
    }

    /// For the render previews, which open the sheet already in a state (a section, arrange mode).
    init(model: SettingsSheetModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ModalSheetScaffold(
            title: "Settings",
            errorMessage: model.visibleError
        ) {
            HStack(alignment: .top, spacing: SettingsMetrics.columnSpacing) {
                sidebar
                sectionColumn
            }
            .padding(.horizontal, SettingsMetrics.inset)
            // Greedy on height so this area absorbs the sheet's fixed 900 x 780 footprint and the
            // content stays pinned to the top.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: SettingsSheetModel.sheetSize.width, height: SettingsSheetModel.sheetSize.height)
        .scoopedPanel()
        .background(FocusSink(nonce: model.sinkNonce))
        .background(SheetKeyEventMonitor(onKeyDown: model.handle))
        .onAppear { model.present() }
        .onDisappear { model.disappear() }
    }

    /// A section's icon in its tab's icon square, at `sectionIconSide`.
    private func sectionImage(_ section: SettingsSection, tint: NSColor) -> NSImage? {
        section.icon.image(glyphSide: SettingsMetrics.sectionIconSide, canvasSide: PillTabMetrics.iconSide, tint: tint)
    }

    private var sidebar: some View {
        VStack(spacing: SettingsMetrics.sidebarSpacing) {
            ForEach(SettingsSection.allCases, id: \.self) { section in
                let selected = section == model.section
                let look: OutlineLook = selected ? .tabSelected : .tabRest
                PillTab(
                    title: section.title,
                    icon: sectionImage(section, tint: look.label.color),
                    look: look,
                    selected: selected,
                    help: "\(section.title) settings",
                    accessibilityLabel: "Settings section \(section.title)"
                )
                .contentShape(Rectangle())
                .onTapGesture { model.selectSection(section) }
            }
        }
        .frame(width: SettingsMetrics.sidebarWidth)
    }

    private var sectionColumn: some View {
        Group {
            switch model.section {
            case .modelsAndReasoning:
                modelsColumn
            case .projects:
                SettingsProjectsView(model: model.projects)
            case .tmux:
                TmuxSettingsView(model: model.tmux)
            }
        }
        .frame(width: SettingsMetrics.columnWidth, alignment: .topLeading)
    }

    private var modelsColumn: some View {
        ZStack(alignment: .topLeading) {
            PillTabRow(
                tabs: model.state.agents.map { .agent($0) },
                selectedID: model.state.selectedAgent,
                // The sheet's tab keys drive these tabs, so they always have keyboard focus.
                focused: true,
                onSelect: { agent in
                    if let index = model.state.agents.firstIndex(of: agent) {
                        model.selectTab(index)
                    }
                }
            )
            availabilityRow
            ForEach(Array(Self.roleGroups.enumerated()), id: \.offset) { offset, group in
                roleSection(role: group.0, title: group.1)
                    .offset(y: SettingsMetrics.firstSectionBaseline + CGFloat(offset) * SettingsMetrics.sectionPitch)
                    .zIndex(RoleDefaultsSettingsModel.roles[model.state.focusedRoleIndex] == group.0 ? 1 : 0)
            }
        }
    }

    private var availabilityRow: some View {
        let agent = model.state.selectedAgent
        let agentName = AgentKind.displayName(for: agent)
        return HStack(alignment: .center, spacing: Space.section) {
            VStack(alignment: .leading, spacing: Space.row) {
                Text("Enable Agent")
                    .font(Font(AppFonts.settingsLabel))
                    .foregroundStyle(AppPalette.textBody.swiftUI)
                Text(model.availabilityStatusMessage(for: agent))
                    .font(Font(AppFonts.settingsDescription))
                    .foregroundStyle(AppPalette.settingsDescription.swiftUI)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Enable \(agentName)", isOn: Binding(
                get: { model.isAgentEnabled(agent) },
                set: { model.setAgentEnabled(agent, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(SettingsAgentSwitchStyle())
            .overlay {
                if model.isAvailabilityToggleFocused(for: agent) {
                    Capsule()
                        .strokeBorder(OutlineLook.field(focused: true).border.color.swiftUI, lineWidth: Token.Size.divider)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Enable \(agentName)")
            .accessibilityValue(model.availabilityAccessibilityValue(for: agent))
            .accessibilityHint("Turning this off hides \(agentName) from New Session and blocks launches. Running sessions stay available.")
            .disabled(!model.isAvailabilityLoaded || model.isSavingAvailability(for: agent) || model.isAvailabilityUnverified(for: agent))
        }
        .frame(width: SettingsMetrics.columnWidth, height: SettingsMetrics.availabilityHeight, alignment: .center)
        .offset(y: SettingsMetrics.availabilityOffset)
    }

    /// Laid out from the title's baseline, which sits at the section's top.
    @ViewBuilder
    private func roleSection(role: String, title: String) -> some View {
        if let rowIndex = model.state.index(agent: model.state.selectedAgent, role: role) {
            let row = model.state.rows[rowIndex]
            let unavailable = !model.canUseAvailability(for: row.agent)
            ZStack(alignment: .topLeading) {
                BaselineText(title, font: AppFonts.settingsSectionTitle, color: AppPalette.text, baseline: 0)
                SettingsSectionRule(width: SettingsMetrics.columnWidth)
                    .offset(y: SettingsMetrics.ruleDrop)
                roleField(role: role, field: .model, title: "Model", isLoading: !row.hasResolvedModelOptions)
                .offset(y: SettingsMetrics.firstRowDrop)
                .zIndex(model.state.focusedField == .model ? 1 : 0)
                roleField(role: role, field: .effort, title: "Reasoning effort", isLoading: !row.hasResolvedEffortOptions)
                .offset(y: SettingsMetrics.firstRowDrop + SettingsMetrics.rowPitch)
            }
            .frame(width: SettingsMetrics.columnWidth, alignment: .topLeading)
            .opacity(model.isAvailabilityLoaded && unavailable ? Token.Opacity.dimmed : 1)
        }
    }

    private func roleField(role: String, field: RoleDefaultField, title: String, isLoading: Bool) -> some View {
        let agent = model.state.selectedAgent
        let focused = !model.isAvailabilityToggleFocused(for: agent)
            && RoleDefaultsSettingsModel.roles[model.state.focusedRoleIndex] == role
            && model.state.focusedField == field
        let unavailable = !model.canUseAvailability(for: agent)
        let disabled = model.isAvailabilityLoaded && unavailable
        let waiting = !model.isAvailabilityLoaded || (!unavailable && isLoading)
        return SettingsRoleRow(title: title, isLoading: waiting) {
            if disabled {
                SettingsSavedDefaultControl(
                    value: model.savedDefault(agent: agent, role: role, field: field),
                    accessibilityLabel: "\(role) \(title)"
                )
            } else {
                FormTextField(
                    text: Binding(
                        get: { model.state.text(role: role, field: field) },
                        set: { model.typePickerText($0, role: role, field: field) }
                    ),
                    placeholder: "Not configured",
                    focusNonce: model.focusNonce(role: role, field: field),
                    focused: focused,
                    onFocusChanged: { editing in
                        if editing { model.search(role: role, field: field) }
                    }
                )
                .accessibilityLabel("\(role) \(title)")
                .suggestionDropdown(focused && model.state.showsPickerSuggestions ? SuggestionDropdown(
                    rows: model.state.pickerSuggestions.map(\.label),
                    highlightedIndex: model.state.pickerWindow.visibleHighlightIndex,
                    onSelect: { model.pickSuggestion(visibleRow: $0) }
                ) : nil)
            }
        }
    }
}

private struct SettingsAgentSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            let look = AppPalette.settingsSwitch(isOn: configuration.isOn)
            Capsule()
                .fill(look.track.swiftUI)
                .overlay { Capsule().strokeBorder(look.border.swiftUI, lineWidth: Token.Size.divider) }
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(look.thumb.swiftUI)
                        .frame(width: ControlHeight.chip, height: ControlHeight.chip)
                        .padding(.horizontal, Token.Size.hairline)
                }
                .frame(width: Space.group, height: Space.section)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : Token.Opacity.dimmed)
        .accessibilityRepresentation {
            Toggle(isOn: Binding(get: { configuration.isOn }, set: { configuration.isOn = $0 })) {
                configuration.label
            }
            .toggleStyle(.switch)
        }
    }
}

/// A saved value remains readable when its agent is disabled, while avoiding
/// a focusable field or suggestion list.
private struct SettingsSavedDefaultControl: View {
    let value: String
    let accessibilityLabel: String

    var body: some View {
        BaselineText(
            value.isEmpty ? "Not configured" : value,
            font: AppFonts.questLogBody,
            color: value.isEmpty ? AppPalette.textMeta : AppPalette.textBody,
            baseline: FormFieldMetrics.baseline
        )
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, FormFieldMetrics.textInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .fieldChrome(focused: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value.isEmpty ? "Not configured" : value)
    }
}

private struct AgentAvailabilitySetAck: Decodable {
    let agent: String
    let enabled: Bool
}

/// The rule under a section title: a 1pt line with the Quest Log's rule vines at each end. `QuestLogArt`
/// draws them about its rule at y 206 from x 20; here they hang off a line at the frame's top.
struct SettingsSectionRule: View {
    let width: CGFloat

    private static let svgRuleY: CGFloat = 206
    private static let svgVineLeft: CGFloat = 20
    private static let svgVineRight: CGFloat = 453
    /// The vine art stands 8 above the line and 9 below it, inside a 20pt band; the line runs 4 in from each end, into
    /// the vines' path data.
    private static let svgReachAbove: CGFloat = 8
    private static let bandHeight: CGFloat = 20
    private static let svgLineInset: CGFloat = 4

    var body: some View {
        Canvas { context, _ in
            let color = GraphicsContext.Shading.color(AppPalette.line.swiftUI)
            let dy = Self.svgReachAbove - Self.svgRuleY
            let pieces = QuestLogArt.ruleVineLeft.map { (SVGPath.parse($0.d, dx: -Self.svgVineLeft, dy: dy), $0.evenOdd) }
                + QuestLogArt.ruleVineRight.map { (SVGPath.parse($0.d, dx: width - Self.svgVineRight, dy: dy), $0.evenOdd) }
            for (path, evenOdd) in pieces {
                context.fill(path, with: color, style: FillStyle(eoFill: evenOdd))
            }
            context.fill(Path(CGRect(x: Self.svgLineInset, y: Self.svgReachAbove, width: width - 2 * Self.svgLineInset, height: Token.Size.divider)), with: color)
        }
        .frame(width: width, height: Self.bandHeight)
        .offset(y: -Self.svgReachAbove)
    }
}

/// A label and the same searchable field used in New Session, with no description line.
private struct SettingsRoleRow<Input: View>: View {
    let title: String
    let isLoading: Bool
    @ViewBuilder var input: () -> Input

    var body: some View {
        HStack(alignment: .top, spacing: Space.item) {
            BaselineText(title, font: AppFonts.settingsLabel, color: AppPalette.text, baseline: SettingsMetrics.labelBaseline)
                .frame(width: SettingsMetrics.labelWidth, alignment: .leading)
            if isLoading {
                SettingsSkeletonControl()
            } else {
                input()
            }
        }
        .frame(width: SettingsMetrics.columnWidth, height: SettingsMetrics.pickerHeight, alignment: .topLeading)
    }
}

/// A ghost of the picker, shown in its place until its options resolve: the picker's own field chrome around a ghost of
/// its value, breathing as the other skeletons do (`SkeletonPulse`).
private struct SettingsSkeletonControl: View {
    var body: some View {
        SkeletonPulse(from: SettingsMetrics.skeletonPulseFrom, to: SettingsMetrics.skeletonPulseTo) {
            SkeletonBar(width: SettingsMetrics.skeletonValueWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .fieldChrome(focused: false)
        }
    }
}

@MainActor
final class SettingsSheetModel: ObservableObject {
    /// Deliberately taller than the tab redesign's own content — the sheet
    /// keeps its original footprint, with content anchored to the top
    /// (`alignment: .top` on the frame below) rather than shrinking or
    /// centering in the leftover space.
    nonisolated static let sheetSize = CGSize(width: 900, height: 780)

    @Published var state = RoleDefaultsSettingsModel()
    @Published var section = SettingsSection.modelsAndReasoning
    @Published var errorMessage: String?
    @Published private(set) var availability: AgentAvailability?
    @Published private var availabilityToggleRequestIDs: [String: Int] = [:]
    @Published private var availabilityUnverifiedAgents: Set<String> = []
    @Published private(set) var focusNonces: [String: [RoleDefaultField: Int]] = [:]
    @Published private(set) var sinkNonce = 0
    let projects: SettingsProjectsModel
    let tmux: TmuxSettingsPageModel
    /// The projects' changes redraw the sheet too, since its error row belongs to the sheet.
    private var projectChanges: AnyCancellable?

    private let mutationClient: ServeMutationSending
    private let modelClient: ServeModelSuggesting?
    private let effortClient: ServeReasoningEffortSuggesting?
    private let dismiss: () -> Void

    /// Guards each row's in-flight suggestion fetches independently, so a
    /// response for a model the user has since cycled away from can't
    /// clobber a newer one — mirrors NewSessionSheetModel's request-ID guard.
    private var modelRequestIDs: [Int]
    private var effortRequestIDs: [Int]
    private var suggestionRequestSequence = 0
    private var availabilityRequestID = 0
    private var availabilityRequestStarted = false
    private var availabilityToggleRequestSequence = 0
    private var isShowing = false
    private var focusedAvailabilityToggleAgent: String?

    init(presentation: SettingsSheetPresentation, dismiss: @escaping () -> Void) {
        mutationClient = presentation.mutationClient
        modelClient = presentation.modelClient
        effortClient = presentation.effortClient
        self.dismiss = dismiss
        let rowCount = RoleDefaultsSettingsModel.defaultAgents.count * RoleDefaultsSettingsModel.roles.count
        modelRequestIDs = Array(repeating: 0, count: rowCount)
        effortRequestIDs = Array(repeating: 0, count: rowCount)
        projects = SettingsProjectsModel(runtime: presentation.runtime, mutationClient: presentation.mutationClient)
        tmux = TmuxSettingsPageModel(mutationClient: presentation.mutationClient, openEditor: presentation.openTmuxConfig)
        projectChanges = projects.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// A section's failed save, whichever section it came from, shows in the sheet's error row.
    var visibleError: String? {
        errorMessage ?? projects.errorMessage
    }

    var isAvailabilityLoaded: Bool { availability != nil }

    func isAgentEnabled(_ agent: String) -> Bool {
        availability?.agents.first(where: { $0.name == agent })?.enabled ?? false
    }

    func isSavingAvailability(for agent: String) -> Bool {
        availabilityToggleRequestIDs[agent] != nil
    }

    func isAvailabilityUnverified(for agent: String) -> Bool {
        availabilityUnverifiedAgents.contains(agent)
    }

    func canUseAvailability(for agent: String) -> Bool {
        isAgentEnabled(agent) && !isAvailabilityUnverified(for: agent)
    }

    func availabilityStatusMessage(for agent: String) -> String {
        if isSavingAvailability(for: agent) {
            return isAvailabilityUnverified(for: agent)
                ? "Checking whether this change was saved…"
                : "Saving this preference…"
        }
        if isAvailabilityUnverified(for: agent) {
            return "Status unverified. Close and reopen Settings to reload."
        }
        return "Turning this off hides the agent from New Session and blocks launches. Running sessions stay available."
    }

    func availabilityAccessibilityValue(for agent: String) -> String {
        if isSavingAvailability(for: agent) {
            return isAvailabilityUnverified(for: agent) ? "Checking" : "Saving"
        }
        if isAvailabilityUnverified(for: agent) {
            return "Unverified"
        }
        return isAgentEnabled(agent) ? "Enabled" : "Disabled"
    }

    func isAvailabilityToggleFocused(for agent: String) -> Bool {
        focusedAvailabilityToggleAgent == agent
    }

    func savedDefault(agent: String, role: String, field: RoleDefaultField) -> String {
        guard let value = availability?.agents.first(where: { $0.name == agent })?.defaults[role] else {
            return ""
        }
        return field == .model ? value.model : value.reasoningEffort
    }

    /// Saves one agent's launch preference. Disabling takes effect in the view
    /// immediately; an ambiguous reply is reconciled before the preference is trusted.
    func setAgentEnabled(_ agent: String, enabled: Bool) {
        guard isAvailabilityLoaded,
              !isSavingAvailability(for: agent),
              !isAvailabilityUnverified(for: agent),
              isAgentEnabled(agent) != enabled else {
            return
        }

        let previousEnabled = isAgentEnabled(agent)
        let request: ServeMutationRequest
        do {
            request = try ServeMutationRequests.setAgentEnabled(agent: agent, enabled: enabled)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        errorMessage = nil
        availabilityToggleRequestSequence += 1
        let requestID = availabilityToggleRequestSequence
        availabilityToggleRequestIDs[agent] = requestID
        focusedAvailabilityToggleAgent = agent
        if !enabled {
            updateAgentEnabled(agent, enabled: false)
            state.invalidateOptions(agent: agent)
            invalidateSuggestions(for: agent)
            sinkNonce += 1
        }

        mutationClient.send(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.isShowing,
                      self.availabilityToggleRequestIDs[agent] == requestID else { return }
                switch result {
                case .success(let ack):
                    do {
                        let persisted = try ack.decoded(AgentAvailabilitySetAck.self)
                        guard persisted.agent == agent, persisted.enabled == enabled else {
                            throw ServeClientError.protocolError("agent availability response did not match the request")
                        }
                        self.updateAgentEnabled(agent, enabled: enabled)
                        self.finishAvailabilityToggle(agent, requestID: requestID, verified: true)
                        if enabled {
                            self.requestSuggestions(for: agent)
                        }
                    } catch {
                        self.reconcileAvailabilityToggle(agent, requestedEnabled: enabled, requestID: requestID)
                    }
                case .failure(let error):
                    if (error as? ServeClientError)?.isDefiniteServerRejection == true {
                        self.restoreRejectedAvailabilityToggle(
                            agent,
                            requestID: requestID,
                            previousEnabled: previousEnabled,
                            error: error
                        )
                    } else {
                        self.reconcileAvailabilityToggle(agent, requestedEnabled: enabled, requestID: requestID)
                    }
                }
            }
        }
    }

    /// Keeps every built-in harness present in the tab row while using the
    /// daemon's order for the entries it returned.
    func applyAvailability(_ response: AgentAvailability) {
        var entries = response.agents
        let names = Set(entries.map(\.name))
        for agent in RoleDefaultsSettingsModel.defaultAgents where !names.contains(agent) {
            entries.append(AgentAvailability.Entry(name: agent, enabled: true))
        }
        let orderedNames = entries.map(\.name)
        if state.agents != orderedNames {
            state.reconcileAgents(orderedNames)
            modelRequestIDs = Array(repeating: 0, count: state.rows.count)
            effortRequestIDs = Array(repeating: 0, count: state.rows.count)
        }
        availability = AgentAvailability(agents: entries)
        availabilityUnverifiedAgents.removeAll()
        availabilityToggleRequestIDs.removeAll()
        focusedAvailabilityToggleAgent = canUseAvailability(for: state.selectedAgent) ? nil : state.selectedAgent
    }

    private func readAvailability(completion: @escaping (Result<AgentAvailability, Error>) -> Void) {
        mutationClient.send(ServeMutationRequests.agentAvailability()) { result in
            let decoded = result.flatMap { ack in Result { try ack.decoded(AgentAvailability.self) } }
            DispatchQueue.main.async {
                completion(decoded)
            }
        }
    }

    private func reconcileAvailabilityToggle(_ agent: String, requestedEnabled: Bool, requestID: Int) {
        availabilityUnverifiedAgents.insert(agent)
        readAvailability { [weak self] result in
            guard let self,
                  self.isShowing,
                  self.availabilityToggleRequestIDs[agent] == requestID else { return }
            guard case .success(let response) = result,
                  let enabled = response.agents.first(where: { $0.name == agent })?.enabled else {
                self.finishAvailabilityToggle(agent, requestID: requestID, verified: false)
                return
            }
            self.updateAgentEnabled(agent, enabled: enabled)
            self.finishAvailabilityToggle(agent, requestID: requestID, verified: true)
            if enabled {
                self.requestSuggestions(for: agent)
            }
            if enabled != requestedEnabled {
                let agentName = AgentKind.displayName(for: agent)
                let status = enabled ? "enabled" : "disabled"
                self.errorMessage = "The saved \(agentName) setting is \(status). Try the switch again."
            }
        }
    }

    private func restoreRejectedAvailabilityToggle(
        _ agent: String,
        requestID: Int,
        previousEnabled: Bool,
        error: Error
    ) {
        updateAgentEnabled(agent, enabled: previousEnabled)
        finishAvailabilityToggle(agent, requestID: requestID, verified: true)
        if previousEnabled {
            requestSuggestions(for: agent)
        }
        errorMessage = error.localizedDescription
    }

    private func finishAvailabilityToggle(_ agent: String, requestID: Int, verified: Bool) {
        guard availabilityToggleRequestIDs[agent] == requestID else { return }
        if verified {
            availabilityUnverifiedAgents.remove(agent)
        }
        availabilityToggleRequestIDs.removeValue(forKey: agent)
    }

    private func updateAgentEnabled(_ agent: String, enabled: Bool) {
        guard let availability,
              let updated = availability.updatingEnabled(enabled, for: agent) else {
            return
        }
        self.availability = updated
    }

    private func updateSavedDefault(agent: String, role: String, model: String, reasoningEffort: String) {
        guard let availability,
              let index = availability.agents.firstIndex(where: { $0.name == agent }) else {
            return
        }
        var entries = availability.agents
        let current = entries[index]
        var defaults = current.defaults
        defaults[role] = AgentAvailability.RoleDefault(model: model, reasoningEffort: reasoningEffort)
        entries[index] = AgentAvailability.Entry(name: agent, enabled: current.enabled, defaults: defaults)
        self.availability = AgentAvailability(agents: entries)
    }

    private func requestSuggestionsForEnabledAgents() {
        for index in state.rows.indices where isAgentEnabled(state.rows[index].agent) {
            requestModelSuggestions(rowIndex: index)
            requestEffortSuggestions(rowIndex: index)
        }
    }

    private func requestSuggestions(for agent: String) {
        guard canUseAvailability(for: agent) else { return }
        for index in state.rows.indices where state.rows[index].agent == agent {
            requestModelSuggestions(rowIndex: index)
            requestEffortSuggestions(rowIndex: index)
        }
    }

    private func invalidateSuggestions(for agent: String) {
        for index in state.rows.indices where state.rows[index].agent == agent {
            modelRequestIDs[index] = nextSuggestionRequestID()
            effortRequestIDs[index] = nextSuggestionRequestID()
        }
    }

    private func nextSuggestionRequestID() -> Int {
        suggestionRequestSequence += 1
        return suggestionRequestSequence
    }

    func selectSection(_ next: SettingsSection) {
        state.endPickerSearch()
        focusedAvailabilityToggleAgent = next == .modelsAndReasoning && !canUseAvailability(for: state.selectedAgent) ? state.selectedAgent : nil
        sinkNonce += 1
        section = next
        if next == .tmux { tmux.loadIfNeeded() }
    }

    /// K and J step up and down through the sidebar's sections, wrapping as the agent tabs do. Arranging holds the section: Save
    /// or Esc ends it first.
    private func moveSection(_ delta: Int) {
        guard !projects.isArranging else {
            return
        }
        let sections = SettingsSection.allCases
        guard let index = sections.firstIndex(of: section) else {
            return
        }
        selectSection(sections[(index + delta + sections.count) % sections.count])
    }

    func present() {
        isShowing = true
        if section == .tmux { tmux.loadIfNeeded() }
        guard !availabilityRequestStarted else {
            return
        }
        availabilityRequestStarted = true
        availabilityRequestID += 1
        let requestID = availabilityRequestID
        readAvailability { [weak self] result in
            guard let self, self.isShowing, self.availabilityRequestID == requestID else { return }
            switch result {
            case .success(let response):
                self.applyAvailability(response)
                self.errorMessage = nil
                self.requestSuggestionsForEnabledAgents()
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Invalidates any in-flight suggestion fetches so a response arriving
    /// after the sheet closes cannot mutate state nobody will ever see.
    func disappear() {
        isShowing = false
        availabilityRequestStarted = false
        availabilityRequestID += 1
        availabilityUnverifiedAgents.formUnion(availabilityToggleRequestIDs.keys)
        availabilityToggleRequestIDs.removeAll()
        for index in modelRequestIDs.indices {
            modelRequestIDs[index] = nextSuggestionRequestID()
        }
        for index in effortRequestIDs.indices {
            effortRequestIDs[index] = nextSuggestionRequestID()
        }
    }

    func focus(role: String, field: RoleDefaultField) {
        guard let roleIndex = RoleDefaultsSettingsModel.roles.firstIndex(of: role) else {
            return
        }
        focusedAvailabilityToggleAgent = nil
        state.focusedRoleIndex = roleIndex
        state.focusedField = field
    }

    func selectTab(_ index: Int) {
        state.selectTab(index)
        focusedAvailabilityToggleAgent = canUseAvailability(for: state.selectedAgent) ? nil : state.selectedAgent
        sinkNonce += 1
    }

    private func moveTab(_ delta: Int) {
        state.moveTab(delta)
        focusedAvailabilityToggleAgent = canUseAvailability(for: state.selectedAgent) ? nil : state.selectedAgent
        sinkNonce += 1
    }

    func focusNonce(role: String, field: RoleDefaultField) -> Int {
        focusNonces[role]?[field] ?? 0
    }

    func search(role: String, field: RoleDefaultField) {
        guard canUseAvailability(for: state.selectedAgent) else { return }
        focus(role: role, field: field)
        if state.pickerMode == .select { applyPickerCommand(.startSearch(.editCurrent)) }
    }

    func typePickerText(_ text: String, role: String, field: RoleDefaultField) {
        guard canUseAvailability(for: state.selectedAgent) else { return }
        search(role: role, field: field)
        state.typePickerText(text)
    }

    func pickSuggestion(visibleRow: Int) {
        guard canUseAvailability(for: state.selectedAgent) else { return }
        changeFocusedValue { self.state.pickSuggestion(visibleRow: visibleRow) }
    }

    private func applyPickerCommand(_ command: PickerFieldCommand) {
        changeFocusedValue { self.state.applyPickerCommand(command) }
    }

    /// The focused picker takes its keys first; the shared modal keys move between fields. Changes apply as they are picked.
    func handle(_ event: NSEvent) -> Bool {
        ModalKeyActions(
            context: { self.modalKeyContext },
            fieldKey: { self.handleFieldKey($0) },
            submit: { self.submit() },
            cancel: { self.cancel() },
            moveFocus: { self.moveFocus($0) },
            cycle: { self.cycleFocused($0) }
        ).handle(event)
    }

    /// The models section is a form with searchable fields. Projects and Tmux remain lists.
    private var modalKeyContext: ModalKeyContext {
        switch section {
        case .modelsAndReasoning:
            return ModalKeyContext(focus: state.pickerMode == .search ? .line : .select, fieldCount: RoleDefaultsSettingsModel.focusableFieldCount + 1, hasTextFields: true, submitting: false, submits: false)
        case .projects:
            return ModalKeyContext(focus: nil, fieldCount: projects.entries.count, hasTextFields: false, submitting: false, submits: true)
        case .tmux:
            return ModalKeyContext(focus: nil, fieldCount: TmuxSettingsAction.allCases.count, hasTextFields: false, submitting: false, submits: true)
        }
    }

    private func submit() {
        switch section {
        case .modelsAndReasoning: break
        case .projects: projects.submit()
        case .tmux: tmux.performFocused()
        }
    }

    /// Esc leaves arrange mode and stays in Settings; anywhere else it closes the sheet.
    private func cancel() {
        if section == .projects, projects.isArranging {
            projects.cancelArrange()
        } else {
            close()
        }
    }

    private func moveFocus(_ delta: Int) {
        switch section {
        case .modelsAndReasoning:
            state.endPickerSearch()
            let agent = state.selectedAgent
            guard canUseAvailability(for: agent) else {
                focusedAvailabilityToggleAgent = agent
                sinkNonce += 1
                return
            }
            let current = state.focusedRoleIndex * 2 + (state.focusedField == .model ? 0 : 1)
            if focusedAvailabilityToggleAgent == agent {
                focusedAvailabilityToggleAgent = nil
                let target = delta > 0 ? 0 : RoleDefaultsSettingsModel.focusableFieldCount - 1
                state.focusedRoleIndex = target / 2
                state.focusedField = target.isMultiple(of: 2) ? .model : .effort
            } else if (delta < 0 && current == 0) || (delta > 0 && current == RoleDefaultsSettingsModel.focusableFieldCount - 1) {
                focusedAvailabilityToggleAgent = agent
            } else {
                state.moveFocus(delta)
            }
            sinkNonce += 1
        case .projects:
            projects.moveHighlight(by: delta)
        case .tmux:
            tmux.moveFocus(delta)
        }
    }

    private func cycleFocused(_ delta: Int) {
        guard section == .modelsAndReasoning else {
            return
        }
        cycleFocusedValue(delta)
    }

    private func handleFieldKey(_ event: NSEvent) -> Bool {
        let press = event.keymapPress
        if section == .modelsAndReasoning,
           state.pickerMode != .search,
           isAvailabilityToggleFocused(for: state.selectedAgent),
           press.keyCode == 49,
           press.modifiers.isEmpty {
            setAgentEnabled(state.selectedAgent, enabled: !isAgentEnabled(state.selectedAgent))
            return true
        }
        if section == .modelsAndReasoning, state.pickerMode == .search {
            // Printable section/tab shortcuts belong to the query while editing.
            return handlePickerKey(press)
        }
        if section == .projects, projects.isArranging {
            return projects.handleKey(press)
        }
        if Keymap.matches(press, .previousSection) {
            moveSection(-1)
            return true
        }
        if Keymap.matches(press, .nextSection) {
            moveSection(1)
            return true
        }
        if section == .projects {
            return projects.handleKey(press)
        }
        if Keymap.matches(press, .previousTab) {
            moveTab(-1)
            return true
        }
        if Keymap.matches(press, .nextTab) {
            moveTab(1)
            return true
        }
        return section == .modelsAndReasoning && handlePickerKey(press)
    }

    private func handlePickerKey(_ press: Keymap.KeyPress) -> Bool {
        guard canUseAvailability(for: state.selectedAgent), !isAvailabilityToggleFocused(for: state.selectedAgent) else { return false }
        guard let command = PickerFieldKey.command(press, mode: state.pickerMode, showsSuggestions: state.showsPickerSuggestions) else { return false }
        applyPickerCommand(command)
        return true
    }

    /// Closes the sheet. Every change already applies the moment it's made,
    /// so there's no separate commit/discard step left — closing never waits
    /// on an in-flight save. A save that fails after the sheet is gone has
    /// nowhere left to show its error; that's an accepted tradeoff of
    /// applying live instead of batching behind a confirm step.
    func close() {
        disappear()
        dismiss()
    }

    /// Cycles whichever field currently has focus and, if that actually
    /// changed the row's value, sends it immediately. Changing the model
    /// invalidates the effort list (valid levels can depend on the model), so
    /// only that case re-fetches; cycling the effort itself needs no refetch.
    private func cycleFocusedValue(_ delta: Int) {
        guard !isAvailabilityToggleFocused(for: state.selectedAgent) else { return }
        changeFocusedValue { self.state.cycleFocusedValue(delta) }
    }

    /// Query edits never persist. A pick or cycle saves only an actual selection change.
    private func changeFocusedValue(_ change: () -> Void) {
        guard canUseAvailability(for: state.selectedAgent), !isAvailabilityToggleFocused(for: state.selectedAgent) else {
            return
        }
        guard let rowIndex = state.focusedRowIndex else {
            return
        }
        let field = state.focusedField
        let previousRow = state.rows[rowIndex]
        let previousMode = state.pickerMode
        change()
        switch PickerFieldMode.caretChange(from: previousMode, to: state.pickerMode, fieldFocused: true) {
        case .intoText: focusNonces[previousRow.role, default: [:]][field, default: 0] += 1
        case .outOfText: sinkNonce += 1
        case nil: break
        }
        let row = state.rows[rowIndex]
        // Guards against sending both fields empty (which the backend
        // rejects) when a cycle press lands before this row's options have
        // resolved and produces no real change.
        guard row.selectedModel != previousRow.selectedModel || row.selectedReasoningEffort != previousRow.selectedReasoningEffort else {
            return
        }
        if row.selectedModel != previousRow.selectedModel {
            requestEffortSuggestions(rowIndex: rowIndex)
        }
        errorMessage = nil
        sendRoleDefault(agent: row.agent, role: row.role, model: row.selectedModel, reasoningEffort: row.selectedReasoningEffort)
    }

    private func requestModelSuggestions(rowIndex: Int) {
        guard let modelClient,
              state.rows.indices.contains(rowIndex),
              canUseAvailability(for: state.rows[rowIndex].agent) else {
            return
        }
        let requestID = nextSuggestionRequestID()
        modelRequestIDs[rowIndex] = requestID
        let row = state.rows[rowIndex]
        modelClient.suggestModels(agent: row.agent, role: row.role, refresh: false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.modelRequestIDs.indices.contains(rowIndex),
                      self.modelRequestIDs[rowIndex] == requestID,
                      self.canUseAvailability(for: row.agent) else {
                    return
                }
                if case .success(let response) = result {
                    self.state.setModelOptions(
                        response.models,
                        defaultModel: response.defaultModel,
                        agent: row.agent,
                        role: row.role
                    )
                }
            }
        }
    }

    private func requestEffortSuggestions(rowIndex: Int) {
        guard let effortClient,
              state.rows.indices.contains(rowIndex),
              canUseAvailability(for: state.rows[rowIndex].agent) else {
            return
        }
        let requestID = nextSuggestionRequestID()
        effortRequestIDs[rowIndex] = requestID
        let row = state.rows[rowIndex]
        let model = row.selectedModel
        effortClient.suggestReasoningEfforts(agent: row.agent, role: row.role, model: model) { [weak self] result in
            DispatchQueue.main.async {
                guard let self,
                      self.effortRequestIDs.indices.contains(rowIndex),
                      self.effortRequestIDs[rowIndex] == requestID,
                      self.canUseAvailability(for: row.agent) else {
                    return
                }
                if case .success(let response) = result {
                    self.state.setEffortOptions(
                        response.efforts,
                        defaultLevel: response.defaultEffort,
                        agent: row.agent,
                        role: row.role
                    )
                }
            }
        }
    }

    private func sendRoleDefault(agent: String, role: String, model: String, reasoningEffort: String) {
        guard canUseAvailability(for: agent) else {
            return
        }
        do {
            let request = try ServeMutationRequests.setRoleDefault(agent: agent, role: role, model: model, reasoningEffort: reasoningEffort)
            mutationClient.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    switch result {
                    case .success(let ack):
                        let persisted = ack.data as? [String: Any]
                        let savedModel = persisted?["model"] as? String ?? model
                        let savedEffort = persisted?["reasoning_effort"] as? String ?? reasoningEffort
                        self.updateSavedDefault(agent: agent, role: role, model: savedModel, reasoningEffort: savedEffort)
                        self.state.markSaved(
                            agent: agent,
                            role: role,
                            model: savedModel,
                            reasoningEffort: savedEffort,
                            sentModel: model,
                            sentReasoningEffort: reasoningEffort
                        )
                    case .failure(let error):
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
