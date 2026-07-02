import QuestmasterCore
import SwiftUI

struct ArtifactFilterOption: Equatable, Identifiable {
    var id: String
    var title: String
}

struct ArtifactDockModel: Equatable {
    var currentSessionTitle: String
    var currentSessionID: String
    var artifacts: [ArtifactReference]
    var projectTitlesByArtifactID: [String: String] = [:]
    var artifactScope: ArtifactScope
    var selectedArtifactID: String?
    var route: ArtifactDockRoute
    var displayState: ArtifactViewerDisplayState
    var artifactFilterQuery: String = ""
    var artifactProjectFilterIDs: Set<String> = []
    var artifactTypeFilterIDs: Set<String> = []
    var projectFilterOptions: [ArtifactFilterOption] = []
    var typeFilterOptions: [ArtifactFilterOption] = []
    var filterFocusNonce: Int = 0
    /// Bumped to force the viewer to reload the current artifact on demand.
    var reloadNonce: Int = 0

    static let empty = ArtifactDockModel(
        currentSessionTitle: "",
        currentSessionID: "",
        artifacts: [],
        artifactScope: .session,
        selectedArtifactID: nil,
        route: .list,
        displayState: .noCurrentSession
    )
}

struct ArtifactDockView: View {
    var model: ArtifactDockModel
    var onSelectArtifact: (String) -> Void
    var onSetScope: (ArtifactScope) -> Void
    var onSetFilterQuery: (String) -> Void
    var onSetProjectFilter: (String, Bool) -> Void
    var onSetTypeFilter: (String, Bool) -> Void
    var onOpenExternal: (URL) -> Void

    @FocusState private var filterFocused: Bool

    var body: some View {
        switch model.route {
        case .list:
            artifactSelector
        case .viewer:
            ArtifactViewerPane(
                displayState: model.displayState,
                reloadNonce: model.reloadNonce,
                onOpenExternal: onOpenExternal
            )
        }
    }

    private var artifactSelector: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopePicker
            if model.artifactScope == .all {
                filterControls
            }
            switch model.displayState {
            case .noCurrentSession:
                selectorStatus("No current session.", detail: "Select a running session in the tracker.")
            case .empty:
                selectorStatus(emptyTitle, detail: emptyDetail)
            case .missing, .unsupported, .viewing:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.artifacts) { artifact in
                                ArtifactRow(
                                    artifact: artifact,
                                    projectTitle: projectTitle(for: artifact),
                                    selected: artifact.id == model.selectedArtifactID,
                                    action: { onSelectArtifact(artifact.id) }
                                )
                                .id(artifact.id)
                            }
                        }
                        .padding(Token.Spacing.card)
                    }
                    .accessibilityLabel("Artifact list")
                    .onAppear {
                        scrollSelectedArtifact(with: proxy)
                    }
                    .onChange(of: model.selectedArtifactID) { _, _ in
                        scrollSelectedArtifact(with: proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.artifactListColumn.swiftUI)
    }

    private var filterBinding: Binding<String> {
        Binding(
            get: { model.artifactFilterQuery },
            set: onSetFilterQuery
        )
    }

    private var filterControls: some View {
        VStack(spacing: Token.Spacing.inline) {
            filterField
            HStack(spacing: Token.Spacing.inline) {
                filterMenu(
                    title: "Project",
                    allTitle: "All Projects",
                    selectedIDs: model.artifactProjectFilterIDs,
                    options: model.projectFilterOptions,
                    onSet: onSetProjectFilter
                )
                filterMenu(
                    title: "Type",
                    allTitle: "All Types",
                    selectedIDs: model.artifactTypeFilterIDs,
                    options: model.typeFilterOptions,
                    onSet: onSetTypeFilter
                )
            }
        }
        .padding(.horizontal, Token.Spacing.card)
        .padding(.bottom, Token.Spacing.card)
    }

    private var filterField: some View {
        HStack(spacing: Token.Spacing.inline) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppPalette.muted.swiftUI)
            TextField("Filter artifacts", text: filterBinding)
                .textFieldStyle(.plain)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.text.swiftUI)
                .focused($filterFocused)
        }
        .padding(.horizontal, Token.Spacing.element)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .fill(AppPalette.panel.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.control)
                        .strokeBorder(AppPalette.line.swiftUI, lineWidth: 1)
                )
        )
        .accessibilityLabel("Filter artifacts")
        .onChange(of: model.filterFocusNonce) { _, _ in
            if model.artifactScope == .all {
                filterFocused = true
            }
        }
    }

    private func filterMenu(
        title: String,
        allTitle: String,
        selectedIDs: Set<String>,
        options: [ArtifactFilterOption],
        onSet: @escaping (String, Bool) -> Void
    ) -> some View {
        Menu {
            ForEach(options.filter { !$0.id.isEmpty }) { option in
                Toggle(
                    option.title,
                    isOn: Binding(
                        get: { selectedIDs.contains(option.id) },
                        set: { onSet(option.id, $0) }
                    )
                )
            }
        } label: {
            Text(filterTitle(allTitle: allTitle, selectedIDs: selectedIDs, options: options))
                .font(AppFonts.body.swiftUI)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .help(title)
        .accessibilityLabel("\(title) filter")
    }

    private func filterTitle(
        allTitle: String,
        selectedIDs: Set<String>,
        options: [ArtifactFilterOption]
    ) -> String {
        guard !selectedIDs.isEmpty else {
            return allTitle
        }
        if selectedIDs.count == 1,
           let id = selectedIDs.first,
           let option = options.first(where: { $0.id == id }) {
            return option.title
        }
        return "\(selectedIDs.count) \(allTitle == "All Types" ? "Types" : "Projects")"
    }

    private var emptyTitle: String {
        hasActiveFilter ? "No matching artifacts." : model.artifactScope.emptyTitle
    }

    private var emptyDetail: String {
        hasActiveFilter ? "Clear the filter to show all artifacts." : model.artifactScope.emptyDetail
    }

    private var hasActiveFilter: Bool {
        !model.artifactFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.artifactProjectFilterIDs.isEmpty
            || !model.artifactTypeFilterIDs.isEmpty
    }

    private func scrollSelectedArtifact(with proxy: ScrollViewProxy) {
        guard let selectedArtifactID = model.selectedArtifactID,
              model.artifacts.contains(where: { $0.id == selectedArtifactID }) else {
            return
        }
        proxy.scrollTo(selectedArtifactID, anchor: .center)
    }

    private func projectTitle(for artifact: ArtifactReference) -> String {
        model.projectTitlesByArtifactID[artifact.id] ?? "Unknown Project"
    }

    private var scopePicker: some View {
        HStack(spacing: Token.Spacing.hairline) {
            ForEach(ArtifactScope.allCases, id: \.rawValue) { scope in
                Button {
                    onSetScope(scope)
                } label: {
                    Text(scope.title)
                        .font(AppFonts.body.swiftUI)
                        .foregroundStyle((scope == model.artifactScope ? AppPalette.activeText : AppPalette.muted).swiftUI)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            RoundedRectangle(cornerRadius: Token.Radius.segment)
                                .fill((scope == model.artifactScope ? AppPalette.controlFill : .clear).swiftUI)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Token.Radius.segment)
                                        .strokeBorder((scope == model.artifactScope ? AppPalette.activeControlBorder : .clear).swiftUI, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("Show \(scope.title.lowercased()) artifacts")
                .accessibilityLabel("Artifact scope \(scope.title)")
                .accessibilityValue(scope == model.artifactScope ? "Selected" : "")
            }
        }
        .padding(Token.Spacing.tight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .fill(AppPalette.panel.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.card)
                        .strokeBorder(AppPalette.line.swiftUI, lineWidth: 1)
                )
        )
        .padding(Token.Spacing.card)
    }

    private func selectorStatus(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(AppFonts.bodyBold.swiftUI)
                .foregroundStyle(AppPalette.bright.swiftUI)
            Text(detail)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Token.Spacing.content)
    }
}

private extension ArtifactScope {
    var title: String {
        switch self {
        case .session:
            return "Session"
        case .project:
            return "Project"
        case .all:
            return "All"
        }
    }

    var emptyTitle: String {
        switch self {
        case .session:
            return "No session artifacts."
        case .project:
            return "No project artifacts."
        case .all:
            return "No artifacts."
        }
    }

    var emptyDetail: String {
        switch self {
        case .session:
            return "Run qm artifact add from this session."
        case .project:
            return "No artifacts registered for this project."
        case .all:
            return "No artifacts registered yet."
        }
    }
}

private struct ArtifactRow: View {
    var artifact: ArtifactReference
    var projectTitle: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.label)
                        .font(AppFonts.body.swiftUI)
                        .foregroundStyle(selected ? AppPalette.bright.swiftUI : AppPalette.text.swiftUI)
                        .lineLimit(1)
                    HStack(spacing: Token.Spacing.inline) {
                        Text(projectTitle)
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.dim.swiftUI)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let addedDate {
                            Text(addedDate)
                                .font(AppFonts.monoSmall.swiftUI)
                                .foregroundStyle(AppPalette.muted.swiftUI)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Token.Spacing.card)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .stroke(selected ? AppPalette.activeControlBorder.swiftUI : .clear, lineWidth: 1)
            )
            .cornerRadius(Token.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(artifact.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(artifact.label)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Open artifact")
    }

    private var accessibilityValue: String {
        var parts = [artifact.path]
        if artifact.missing {
            parts.append("Missing")
        }
        if selected {
            parts.append("Selected")
        }
        return parts.joined(separator: ", ")
    }

    private var addedDate: String? {
        let value = artifact.addedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 10 else {
            return nil
        }
        let date = String(value.prefix(10))
        let parts = date.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              Int(parts[0]) != nil,
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        return date
    }

    private var iconColor: Color {
        if artifact.missing {
            return AppPalette.warn.swiftUI
        }
        return selected ? AppPalette.accent.swiftUI : AppPalette.muted.swiftUI
    }

    private var iconName: String {
        if artifact.missing {
            return "exclamationmark.triangle"
        }
        switch artifact.resolvedKind {
        case .html:
            return "doc.richtext"
        case .markdown:
            return "doc.text"
        case .image:
            return "photo"
        case .unsupported:
            return "questionmark.square.dashed"
        }
    }

    private var rowBackground: Color {
        selected ? AppPalette.selection.swiftUI : Color.clear
    }
}

private struct ArtifactViewerPane: View {
    var displayState: ArtifactViewerDisplayState
    var reloadNonce: Int
    var onOpenExternal: (URL) -> Void

    var body: some View {
        viewerContent
        .background(AppPalette.artifactViewerBackground.swiftUI)
    }

    @ViewBuilder
    private var viewerContent: some View {
        switch displayState {
        case .viewing(let artifact):
            switch artifact.resolvedKind {
            case .html:
                ArtifactWebView(
                    artifact: artifact,
                    reloadNonce: reloadNonce,
                    decideNavigation: ArtifactNavigationPolicy.decide,
                    openExternal: onOpenExternal
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .markdown:
                ArtifactMarkdownView(artifact: artifact, reloadNonce: reloadNonce)
            case .image:
                ArtifactImageView(artifact: artifact, reloadNonce: reloadNonce)
            case .unsupported:
                ArtifactStatusPane(
                    symbolName: "questionmark.square.dashed",
                    title: "Unsupported artifact",
                    message: "This artifact kind is not supported in this build.",
                    detail: artifact.kind
                )
            }
        case .noCurrentSession:
            ArtifactStatusPane(
                symbolName: "rectangle.slash",
                title: "No current session",
                message: "Select a running session in the tracker."
            )
        case .empty:
            ArtifactStatusPane(
                symbolName: "doc",
                title: "No artifacts",
                message: "Run qm artifact add from this session."
            )
        case .missing(let artifact):
            ArtifactStatusPane(
                symbolName: "exclamationmark.triangle",
                title: "Missing file",
                message: "This artifact pointed at a file that no longer exists.",
                detail: artifact.path
            )
        case .unsupported(let artifact):
            ArtifactStatusPane(
                symbolName: "questionmark.square.dashed",
                title: "Unsupported artifact",
                message: "This artifact kind is not supported in this build.",
                detail: artifact.kind
            )
        }
    }

}

struct ArtifactStatusPane: View {
    var symbolName: String
    var title: String
    var message: String
    var detail: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(AppPalette.muted.swiftUI)
            Text(title)
                .font(AppFonts.bodyBold.swiftUI)
                .foregroundStyle(AppPalette.bright.swiftUI)
            Text(message)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail)
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(AppPalette.artifactViewerBackground.swiftUI)
    }
}
