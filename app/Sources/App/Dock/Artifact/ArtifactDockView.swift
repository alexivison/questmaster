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
    var selectedArtifactIDs: Set<String> = []
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
    /// Bumped whenever the selected artifact must scroll into view even if its id didn't change (a
    /// `gg`/`G` jump back to the already-selected edge row).
    var scrollNonce: Int = 0

    static let empty = ArtifactDockModel(
        currentSessionTitle: "",
        currentSessionID: "",
        artifacts: [],
        artifactScope: .session,
        selectedArtifactID: nil,
        selectedArtifactIDs: [],
        route: .list,
        displayState: .noCurrentSession
    )
}

struct ArtifactDockView: View {
    var model: ArtifactDockModel
    var onSelectArtifact: (String) -> Void
    var onToggleArtifact: (String) -> Void
    var onSetScope: (ArtifactScope) -> Void
    var onSetFilterQuery: (String) -> Void
    var onRemoveFilterToken: (ArtifactFilterToken) -> Void
    var onSelectFilterSuggestion: (ArtifactFilterSuggestion) -> Void
    var onFilterCommand: (UInt16) -> Bool
    var onFilterEndEditing: () -> Void
    var onOpenExternal: (URL) -> Void
    /// Whether the dock has keyboard focus: an unfocused dock shows its selection one step dimmer.
    var areaFocused: Bool
    /// Renders the filter as focused (RenderPreview).
    var previewFilterFocused = false

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

    /// artifacts.svg, under the dock's top bar: the Session/All tabs 20 down, the filter (All only) 20 under them,
    /// and the rows 20 under that, everything 20 in from the panel's sides.
    private var artifactSelector: some View {
        VStack(alignment: .leading, spacing: ArtifactPaneMetrics.gap) {
            scopeTabs
            if model.artifactScope == .all {
                filterBar
            }
            switch model.displayState {
            case .noCurrentSession:
                selectorStatus("No current session.", detail: "Select a running session in the tracker.")
            case .empty:
                selectorStatus(emptyTitle, detail: emptyDetail)
            case .missing, .unsupported, .viewing:
                SectionedList(
                    selectedID: model.selectedArtifactID,
                    scrollOnAppear: true,
                    scrollTarget: model.selectedArtifactID.map { ScrollTarget(id: $0, nonce: model.scrollNonce) }
                ) {
                    ForEach(model.artifacts) { artifact in
                        ArtifactRow(
                            artifact: artifact,
                            projectTitle: projectTitle(for: artifact),
                            look: RowLook.pick(highlighted: artifact.id == model.selectedArtifactID, areaFocused: areaFocused),
                            marked: model.selectedArtifactIDs.contains(artifact.id),
                            selectMode: !model.selectedArtifactIDs.isEmpty,
                            onToggle: { onToggleArtifact(artifact.id) },
                            action: { onSelectArtifact(artifact.id) }
                        )
                        .id(artifact.id)
                    }
                }
                .accessibilityLabel("Artifact list")
            }
        }
        .padding(.top, ArtifactPaneMetrics.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.artifactListColumn.swiftUI)
    }

    private var filterBar: some View {
        FilterBar(
            tokens: model.artifactFilterTokens,
            query: Binding(get: { model.artifactFilterQuery }, set: onSetFilterQuery),
            placeholder: "@project or @type or text...",
            focusNonce: model.filterFocusNonce,
            suggestions: model.filterSuggestionsVisible ? model.filterSuggestions : [],
            highlightedSuggestionID: model.selectedFilterSuggestionID,
            accessibilityLabel: "Filter artifacts",
            previewFocused: previewFilterFocused,
            onCommand: onFilterCommand,
            onEndEditing: onFilterEndEditing,
            onRemoveToken: onRemoveFilterToken,
            onSelectSuggestion: onSelectFilterSuggestion
        )
        .padding(.horizontal, ArtifactPaneMetrics.gap)
        .zIndex(2)
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

    private var scopeTabs: some View {
        PillTabRow(
            tabs: ArtifactScope.dockCases.map {
                .init(id: $0, title: $0.title, icon: nil, help: "Show \($0.title.lowercased()) artifacts", accessibilityLabel: "Artifact scope \($0.title)")
            },
            selectedID: model.artifactScope,
            focused: areaFocused,
            spacing: ArtifactPaneMetrics.gap,
            onSelect: onSetScope
        )
        .padding(.horizontal, ArtifactPaneMetrics.gap)
    }

    private func selectorStatus(_ title: String, detail: String) -> some View {
        EmptyStatePane(
            title: title,
            message: detail,
            titleFont: AppFonts.questLogBody.swiftUI,
            titleColor: AppPalette.textBody.swiftUI,
            messageFont: AppFonts.monoSmall.swiftUI,
            messageColor: AppPalette.textMeta.swiftUI,
            padding: EdgeInsets(top: 0, leading: ArtifactPaneMetrics.gap, bottom: ArtifactPaneMetrics.gap, trailing: ArtifactPaneMetrics.gap)
        )
    }
}

/// artifacts.svg's spacing: every part of the pane is 20 from the next and from the panel's sides.
private enum ArtifactPaneMetrics {
    static let gap: CGFloat = 20
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

/// A pick-to-open row, measured from artifact-item-v2.svg: 50 high, radius 5, in its `RowLook` (the fill only while
/// highlighted). The icon tile 40 square at (10, 5), radius 5, with a 1pt border and the 19.2 x 24 icon centred; the
/// title 10 past the tile on a baseline 18.5 down; a 1pt divider at y 25 from the tile to 41 short of the right
/// edge; the project and date on a baseline 39.5 down, the date ending on the divider's end. The 20pt gutters on
/// either side hold the pane's margin; in select mode the left one holds the mark.
private struct ArtifactRow: View {
    var artifact: ArtifactReference
    var projectTitle: String
    var look: RowLook
    var marked: Bool
    var selectMode: Bool
    var onToggle: () -> Void
    var action: () -> Void

    private enum Metrics {
        static let height: CGFloat = 50
        static let spacing: CGFloat = 5
        static let cornerRadius: CGFloat = 5
        static let gutter: CGFloat = 20
        static let tileOrigin = CGPoint(x: 10, y: 5)
        static let tileSide: CGFloat = 40
        static let iconSize = CGSize(width: 19.2, height: 24)
        /// doc.richtext at this size and semibold fills `iconSize`, as the design's glyph does.
        static let iconPointSize: CGFloat = 22.5
        static let textX: CGFloat = 60
        static let trailingInset: CGFloat = 41
        static let titleBaseline: CGFloat = 18.5
        static let dividerY: CGFloat = 25
        static let metaBaseline: CGFloat = 39.5
        static let markSize: CGFloat = 13
    }

    private var rowLook: RowLook { artifact.missing ? look.missingFile : look }

    var body: some View {
        HStack(spacing: 0) {
            markGutter
            row
            Color.clear.frame(width: Metrics.gutter, height: 1)
        }
        .padding(.bottom, Metrics.spacing)
        .animation(.easeInOut(duration: 0.16), value: selectMode)
        .help(artifact.path)
        .accessibilityElement(children: selectMode ? .contain : .ignore)
        .accessibilityLabel(artifact.label)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(selectMode ? "Open artifact or select for deletion" : "Open artifact")
    }

    @ViewBuilder
    private var markGutter: some View {
        ZStack {
            if selectMode {
                Button(action: onToggle) {
                    Image(systemName: marked ? "diamond.inset.filled" : "diamond")
                        .font(.system(size: Metrics.markSize))
                        .foregroundStyle(MarkLook.color(marked: marked).color.swiftUI)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(marked ? "Deselect \(artifact.label)" : "Select \(artifact.label)")
                .transition(.opacity)
            }
        }
        .frame(width: Metrics.gutter, height: Metrics.height)
    }

    private var row: some View {
        GeometryReader { proxy in
            let textWidth = max(0, proxy.size.width - Metrics.trailingInset - Metrics.textX)
            ZStack(alignment: .topLeading) {
                tile
                    .offset(x: Metrics.tileOrigin.x, y: Metrics.tileOrigin.y)
                BaselineText(artifact.label, font: AppFonts.artifactTitle, color: rowLook.text.color, baseline: Metrics.titleBaseline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: textWidth, alignment: .leading)
                    .offset(x: Metrics.textX)
                Rectangle()
                    .fill(AppPalette.line.swiftUI)
                    .frame(width: max(0, proxy.size.width - Metrics.trailingInset - Metrics.tileOrigin.x - Metrics.tileSide), height: Token.Size.divider)
                    .offset(x: Metrics.tileOrigin.x + Metrics.tileSide, y: Metrics.dividerY - Token.Size.divider / 2)
                HStack(spacing: Token.Spacing.element) {
                    BaselineText(projectTitle, font: AppFonts.monoSmall, color: rowLook.meta.color, baseline: Metrics.metaBaseline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let addedDate {
                        BaselineText(addedDate, font: AppFonts.monoSmall, color: rowLook.meta.color, baseline: Metrics.metaBaseline)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                .frame(width: textWidth)
                .offset(x: Metrics.textX)
            }
        }
        .frame(height: Metrics.height)
        .stateRow(rowLook, cornerRadius: Metrics.cornerRadius)
        .onTapGesture(perform: action)
    }

    private var tile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                .fill(AppPalette.panel.swiftUI)
            RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                .strokeBorder(rowLook.iconBorder.color.swiftUI, lineWidth: Token.Size.divider)
            Image(systemName: iconName)
                .font(.system(size: Metrics.iconPointSize, weight: .semibold))
                .frame(width: Metrics.iconSize.width, height: Metrics.iconSize.height)
                .foregroundStyle(rowLook.icon.color.swiftUI)
        }
        .frame(width: Metrics.tileSide, height: Metrics.tileSide)
    }

    private var accessibilityValue: String {
        var parts = [artifact.path]
        if artifact.missing {
            parts.append("Missing")
        }
        if marked {
            parts.append("Selected for deletion")
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
