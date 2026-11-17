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
/// section on the right (x 290-880): the agent tabs, then a "Master" and a "Worker" section, each a bold
/// title over a vine-ended rule and separate searchable model and reasoning fields.
enum SettingsMetrics {
    static let inset = PanelMetrics.contentInset
    static let sidebarWidth: CGFloat = 250
    static let columnSpacing = Space.section
    static let columnWidth = SettingsSheetModel.sheetSize.width - 2 * inset - sidebarWidth - columnSpacing
    static let sidebarSpacing = Space.section
    /// A section's glyph fills its tab's 20pt icon square. The keylined brain, folder and terminal measure 15 x 15, 15 x 14
    /// and 15 x 13 there, against the SF symbols' 15.6 x 15, 16.3 x 13.2 and 16.0 x 12.5 that the tab fitted into that square.
    static let sectionIconSide: CGFloat = PillTabMetrics.iconSide
    /// From the top of the agent tabs: the first section title's baseline, then each next one 175 on.
    static let firstSectionBaseline: CGFloat = 65
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
            ForEach(Array(Self.roleGroups.enumerated()), id: \.offset) { offset, group in
                roleSection(role: group.0, title: group.1)
                    .offset(y: SettingsMetrics.firstSectionBaseline + CGFloat(offset) * SettingsMetrics.sectionPitch)
                    .zIndex(RoleDefaultsSettingsModel.roles[model.state.focusedRoleIndex] == group.0 ? 1 : 0)
            }
        }
    }

    /// Laid out from the title's baseline, which sits at the section's top.
    @ViewBuilder
    private func roleSection(role: String, title: String) -> some View {
        if let rowIndex = model.state.index(agent: model.state.selectedAgent, role: role) {
            let row = model.state.rows[rowIndex]
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
        }
    }

    private func roleField(role: String, field: RoleDefaultField, title: String, isLoading: Bool) -> some View {
        let focused = RoleDefaultsSettingsModel.roles[model.state.focusedRoleIndex] == role && model.state.focusedField == field
        return SettingsRoleRow(title: title, isLoading: isLoading) {
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

    func selectSection(_ next: SettingsSection) {
        state.endPickerSearch()
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
        if section == .tmux { tmux.loadIfNeeded() }
        for index in state.rows.indices {
            requestModelSuggestions(rowIndex: index)
            requestEffortSuggestions(rowIndex: index)
        }
    }

    /// Invalidates any in-flight suggestion fetches so a response arriving
    /// after the sheet closes cannot mutate state nobody will ever see.
    func disappear() {
        for index in modelRequestIDs.indices {
            modelRequestIDs[index] += 1
        }
        for index in effortRequestIDs.indices {
            effortRequestIDs[index] += 1
        }
    }

    func focus(role: String, field: RoleDefaultField) {
        guard let roleIndex = RoleDefaultsSettingsModel.roles.firstIndex(of: role) else {
            return
        }
        state.focusedRoleIndex = roleIndex
        state.focusedField = field
    }

    func selectTab(_ index: Int) {
        state.selectTab(index)
        sinkNonce += 1
    }

    private func moveTab(_ delta: Int) {
        state.moveTab(delta)
        sinkNonce += 1
    }

    func focusNonce(role: String, field: RoleDefaultField) -> Int {
        focusNonces[role]?[field] ?? 0
    }

    func search(role: String, field: RoleDefaultField) {
        focus(role: role, field: field)
        if state.pickerMode == .select { applyPickerCommand(.startSearch(.editCurrent)) }
    }

    func typePickerText(_ text: String, role: String, field: RoleDefaultField) {
        search(role: role, field: field)
        state.typePickerText(text)
    }

    func pickSuggestion(visibleRow: Int) {
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
            return ModalKeyContext(focus: state.pickerMode == .search ? .line : .select, fieldCount: RoleDefaultsSettingsModel.focusableFieldCount, hasTextFields: true, submitting: false, submits: false)
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
            state.moveFocus(delta)
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
        changeFocusedValue { self.state.cycleFocusedValue(delta) }
    }

    /// Query edits never persist. A pick or cycle saves only an actual selection change.
    private func changeFocusedValue(_ change: () -> Void) {
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
        guard let modelClient, state.rows.indices.contains(rowIndex) else {
            return
        }
        modelRequestIDs[rowIndex] += 1
        let requestID = modelRequestIDs[rowIndex]
        let row = state.rows[rowIndex]
        modelClient.suggestModels(agent: row.agent, role: row.role, refresh: false) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.modelRequestIDs[rowIndex] == requestID else {
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
        guard let effortClient, state.rows.indices.contains(rowIndex) else {
            return
        }
        effortRequestIDs[rowIndex] += 1
        let requestID = effortRequestIDs[rowIndex]
        let row = state.rows[rowIndex]
        let model = row.selectedModel
        effortClient.suggestReasoningEfforts(agent: row.agent, role: row.role, model: model) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.effortRequestIDs[rowIndex] == requestID else {
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
                        self.state.markSaved(
                            agent: agent,
                            role: role,
                            model: persisted?["model"] as? String ?? model,
                            reasoningEffort: persisted?["reasoning_effort"] as? String ?? reasoningEffort,
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
