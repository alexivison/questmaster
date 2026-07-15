import AppKit
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
    var artifactFilterTokens: [ArtifactFilterToken] = []
    var filterSuggestions: [ArtifactFilterSuggestion] = []
    var selectedFilterSuggestionID: String?
    var filterSuggestionsVisible: Bool = false
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
    var onRemoveFilterToken: (ArtifactFilterToken) -> Void
    var onSelectFilterSuggestion: (ArtifactFilterSuggestion) -> Void
    var onFilterCommand: (UInt16) -> Bool
    var onFilterEndEditing: () -> Void
    var onOpenExternal: (URL) -> Void

    @State private var filterFocused = false

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
                SectionedList(selectedID: model.selectedArtifactID, scrollOnAppear: true) {
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
                .accessibilityLabel("Artifact list")
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
        filterField
        .overlay(alignment: .topLeading) {
            if filterFocused && model.filterSuggestionsVisible {
                filterSuggestionList
                    .offset(y: 38)
                    .zIndex(3)
            }
        }
        .padding(.horizontal, Token.Spacing.card)
        .padding(.bottom, Token.Spacing.card)
        .zIndex(2)
    }

    private var filterField: some View {
        HStack(spacing: Token.Spacing.inline) {
            Text("/")
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
            ForEach(model.artifactFilterTokens) { token in
                FilterTokenChip(
                    token: token,
                    onRemove: { onRemoveFilterToken(token) }
                )
            }
            CommandTextField(
                text: filterBinding,
                placeholder: "@project: @type: or text",
                focusNonce: model.filterFocusNonce,
                onCommand: onFilterCommand,
                onEndEditing: onFilterEndEditing,
                onFocusChanged: { filterFocused = $0 }
            )
            .frame(minWidth: 80, maxWidth: .infinity, minHeight: 22)
        }
        .padding(.horizontal, Token.Spacing.card)
        .padding(.vertical, 4)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .fill(AppPalette.panel.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.control)
                        .strokeBorder((filterFocused ? AppPalette.accent : AppPalette.line).swiftUI, lineWidth: 1)
                )
        )
        .accessibilityLabel("Filter artifacts")
    }

    private var filterSuggestionList: some View {
        FilterSuggestionList(
            suggestions: model.filterSuggestions,
            selectedID: model.selectedFilterSuggestionID,
            onSelect: onSelectFilterSuggestion
        )
    }

    private var emptyTitle: String {
        hasActiveFilter ? "No matching artifacts." : model.artifactScope.emptyTitle
    }

    private var emptyDetail: String {
        hasActiveFilter ? "Clear the filter to show all artifacts." : model.artifactScope.emptyDetail
    }

    private var hasActiveFilter: Bool {
        model.artifactScope == .all && (
            !model.artifactFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.artifactProjectFilterIDs.isEmpty
            || !model.artifactTypeFilterIDs.isEmpty
        )
    }

    private func projectTitle(for artifact: ArtifactReference) -> String {
        model.projectTitlesByArtifactID[artifact.id] ?? "Unknown Project"
    }

    private var scopePicker: some View {
        SegmentedPicker(
            options: ArtifactScope.dockCases,
            selection: model.artifactScope,
            showsSelectionBorder: true,
            title: \.title,
            onSelect: onSetScope,
            helpText: { "Show \($0.title.lowercased()) artifacts" },
            accessibilityLabel: { "Artifact scope \($0.title)" },
            accessibilityValue: { $0 == model.artifactScope ? "Selected" : "" }
        )
        .padding(Token.Spacing.card)
    }

    private func selectorStatus(_ title: String, detail: String) -> some View {
        EmptyStatePane(
            title: title,
            message: detail,
            padding: EdgeInsets(
                top: Token.Spacing.content,
                leading: Token.Spacing.content,
                bottom: Token.Spacing.content,
                trailing: Token.Spacing.content
            )
        )
    }
}

private extension ArtifactScope {
    static var dockCases: [ArtifactScope] {
        [.session, .all]
    }

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
        ListRow(selected: selected, leadingInset: Token.Spacing.card, onTap: action) { selected, hovered in
            ItemCardShape(selected: selected, hovered: hovered)
        } content: {
            HStack(alignment: .top, spacing: ItemCardShape.iconLabelGap) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.label)
                        .font(AppFonts.itemTitle.swiftUI)
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
            .padding(.leading, ItemCardShape.contentPadding)
            .padding(.trailing, ItemCardShape.trailingContentPadding)
            .padding(.vertical, ItemCardShape.contentPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private var iconColor: Color { iconTintColor.swiftUI }

    private var iconTintColor: NSColor {
        if artifact.missing {
            return AppPalette.warn
        }
        return selected ? AppPalette.accent : AppPalette.muted
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
        EmptyStatePane(
            title: title,
            message: message,
            detail: detail,
            symbolName: symbolName,
            backgroundColor: AppPalette.artifactViewerBackground,
            detailSelectable: true
        )
    }
}
