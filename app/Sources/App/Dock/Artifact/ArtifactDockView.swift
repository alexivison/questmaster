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
    var projectColorsByID: [String: String] = [:]
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
    /// Why the list shows nothing: nothing yet, or the filter hid every artifact the session has.
    var emptyReason: ListEmptyReason = .nothingYet

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
    var onFilterCommand: (Keymap.KeyPress) -> Bool
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

    /// artifacts.svg, under the dock's top bar: the Session/All tabs (10 apart) 20 down, the filter (All only) 20 under
    /// them, and the rows 20 under that, everything 20 in from the panel's sides.
    private var artifactSelector: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            scopeTabs
            if model.artifactScope == .all {
                filterBar
            }
            switch model.displayState {
            case .noCurrentSession, .empty:
                EmptyState(reason: model.emptyReason)
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
                            projectColor: model.projectColorsByID[artifact.projectID] ?? "",
                            look: RowLook.cardPick(
                                highlighted: artifact.id == model.selectedArtifactID,
                                areaFocused: areaFocused,
                                marksInGutter: !model.selectedArtifactIDs.isEmpty
                            ),
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
        .padding(.top, Space.section)
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
        .padding(.horizontal, Space.section)
        .zIndex(2)
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
            onSelect: onSetScope
        )
        .padding(.horizontal, Space.section)
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
}

/// A scooped list card: a recessed icon tile, the title, then the date on the left and the project on the right.
/// The panel's side gutters also leave room for deletion marks.
struct ArtifactRow: View {
    var artifact: ArtifactReference
    var projectTitle: String
    var projectColor: String = ""
    var look: RowLook
    var marked: Bool
    var selectMode: Bool
    var onToggle: () -> Void
    var action: () -> Void

    private enum Metrics {
        static let height = ListItemMetrics.height
        static let spacing = ListItemMetrics.spacing
        static let cornerRadius: CGFloat = 5
        static let gutter = MenuPointerMetrics.gutter
        static let tileOrigin = CGPoint(x: ListItemMetrics.textInset, y: Space.row)
        static let tileSide = ControlHeight.bar
        /// The kind's glyph in its 40pt tile. At 30 the keylined html and markdown measure 20 x 25 against the SF symbols' 19 x 24,
        /// and the missing-file triangle 22 x 20 against 23.5 x 21. The image (20 x 23 against 26 x 20.5) and the question mark
        /// (13 x 25 against 20.5 x 20.5) differ by shape, and 30 is the largest the tile's 5pt inset allows.
        static let iconSide: CGFloat = 30
        static let textX = tileOrigin.x + tileSide + Space.item
        static let trailingInset = ListItemMetrics.textInset
        static let titleBaseline: CGFloat = 21
        static let metaBaseline: CGFloat = 37
        /// The delete mark fills the 20pt gutter's width: its ink (13 x 13) is the SF diamond's (14 x 14) to within a point.
        static let markSide: CGFloat = 20
    }

    private var rowLook: RowLook { artifact.missing ? look.missingFile : look }

    var body: some View {
        HStack(spacing: 0) {
            markGutter
            row
            Color.clear.frame(width: Metrics.gutter, height: 1)
        }
        .padding(.bottom, Metrics.spacing)
        .animation(Motion.animation(.fast), value: selectMode)
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
                    // Outline when unmarked, filled when marked.
                    if let image = AppIcon.artifactDeleteMarkDiamond.image(
                        glyphSide: Metrics.markSide,
                        tint: MarkLook.color(marked: marked).color,
                        filled: marked
                    ) {
                        Image(nsImage: image)
                    }
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
                HStack(spacing: Space.item) {
                    if let addedDate {
                        BaselineText(addedDate, font: AppFonts.monoSmall, color: rowLook.meta.color, baseline: Metrics.metaBaseline)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                    BaselineText(projectTitle, font: AppFonts.monoSmall, color: AppPalette.projectLabel(projectColor, fallback: rowLook.meta.color), baseline: Metrics.metaBaseline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: textWidth)
                .offset(x: Metrics.textX)
            }
        }
        .frame(height: Metrics.height)
        .stateRow(rowLook, scoopRadius: ListItemMetrics.scoopRadius)
        .onTapGesture(perform: action)
    }

    private var tile: some View {
        ZStack {
            Canvas { context, size in
                let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: Metrics.cornerRadius)
                context.fill(shape, with: .color(AppPalette.panel.swiftUI))
                context.fillInnerShadow(shape, Recess.listItemIcon)
            }
            RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                .strokeBorder(rowLook.iconBorder.color.swiftUI, lineWidth: Token.Size.divider)
            if let image = kindIcon.image(glyphSide: Metrics.iconSide, tint: rowLook.icon.color) {
                Image(nsImage: image)
            }
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

    private var kindIcon: AppIcon {
        if artifact.missing {
            return .artifactMissingHazard
        }
        switch artifact.resolvedKind {
        case .html:
            return .artifactHTMLTome
        case .markdown:
            return .artifactMarkdownNotebook
        case .image:
            return .artifactImagePortrait
        case .unsupported:
            return .artifactUnsupportedQuestion
        }
    }
}

struct ArtifactViewerPane: View {
    var displayState: ArtifactViewerDisplayState
    var reloadNonce: Int
    var onOpenExternal: (URL) -> Void
    var ruleListCompiler: any ArtifactRuleListCompiling = WebKitRuleListCompiler()

    @State private var htmlLoading = true
    /// Set when the remote-content blocker failed to compile: the page is not loaded, and this says why.
    @State private var htmlBlockedDetail: String?

    private enum SkeletonMetrics {
        static let titleWidth: CGFloat = 180
        static let lineWidths: [CGFloat] = [320, 290, 340, 250]
        static let pulseFrom = 0.6
        static let pulseTo = 0.7
    }

    var body: some View {
        viewerContent
            .background(AppPalette.artifactViewerBackground.swiftUI)
            // A blocked page takes its web view down, so the reset lives here, where it outlives that view: another
            // artifact or a refresh gets a fresh attempt at the blocker.
            .onChange(of: viewedPath) { _, _ in htmlBlockedDetail = nil }
            .onChange(of: reloadNonce) { _, _ in htmlBlockedDetail = nil }
    }

    private var viewedPath: String? {
        guard case .viewing(let artifact) = displayState else {
            return nil
        }
        return artifact.path
    }

    @ViewBuilder
    private var viewerContent: some View {
        switch displayState {
        case .viewing(let artifact):
            switch artifact.resolvedKind {
            case .html:
                if let htmlBlockedDetail {
                    ArtifactStatusPane(
                        glyph: .symbol("shield.slash"),
                        title: "Page not loaded",
                        message: "The remote-content blocker failed to compile, so this page did not load.",
                        detail: htmlBlockedDetail
                    )
                } else {
                    ArtifactWebView(
                        artifact: artifact,
                        reloadNonce: reloadNonce,
                        decideNavigation: ArtifactNavigationPolicy.decide,
                        openExternal: onOpenExternal,
                        onLoadingChange: { htmlLoading = $0 },
                        onRuleListFailure: { htmlBlockedDetail = $0 },
                        ruleListCompiler: ruleListCompiler
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { if htmlLoading { htmlLoadingSkeleton } }
                    .onAppear { htmlLoading = true }
                    .onChange(of: artifact.path) { _, _ in htmlLoading = true }
                    .onChange(of: reloadNonce) { _, _ in htmlLoading = true }
                }
            case .markdown:
                ArtifactMarkdownView(artifact: artifact, reloadNonce: reloadNonce)
            case .image:
                ArtifactImageView(artifact: artifact, reloadNonce: reloadNonce)
            case .unsupported:
                ArtifactStatusPane(
                    glyph: .icon(.artifactUnsupportedQuestion),
                    title: "Unsupported artifact",
                    message: "This artifact kind is not supported in this build.",
                    detail: artifact.kind
                )
            }
        case .noCurrentSession, .empty:
            EmptyState()
        case .missing(let artifact):
            ArtifactStatusPane(
                glyph: .icon(.artifactMissingHazard),
                title: "Missing file",
                message: "This artifact pointed at a file that no longer exists.",
                detail: artifact.path
            )
        case .unsupported(let artifact):
            ArtifactStatusPane(
                glyph: .icon(.artifactUnsupportedQuestion),
                title: "Unsupported artifact",
                message: "This artifact kind is not supported in this build.",
                detail: artifact.kind
            )
        }
    }

    private var htmlLoadingSkeleton: some View {
        SkeletonPulse(from: SkeletonMetrics.pulseFrom, to: SkeletonMetrics.pulseTo) {
            VStack(alignment: .leading, spacing: Space.item) {
                SkeletonBar(width: SkeletonMetrics.titleWidth, height: Space.section)
                    .padding(.bottom, Space.item)
                ForEach(Array(SkeletonMetrics.lineWidths.enumerated()), id: \.offset) { _, width in
                    SkeletonBar(width: width)
                }
            }
            .padding(Space.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(AppPalette.artifactViewerBackground.swiftUI)
        .accessibilityLabel("Loading artifact")
    }
}

struct ArtifactStatusPane: View {
    var glyph: AppGlyph
    var title: String
    var message: String
    var detail: String = ""

    var body: some View {
        StatusMessagePane(
            title: title,
            message: message,
            detail: detail,
            glyph: glyph,
            backgroundColor: AppPalette.artifactViewerBackground,
            detailSelectable: true
        )
    }
}
