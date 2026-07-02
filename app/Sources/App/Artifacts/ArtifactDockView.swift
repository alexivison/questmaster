import QuestmasterCore
import SwiftUI

struct ArtifactDockModel: Equatable {
    var currentSessionTitle: String
    var currentSessionID: String
    var artifacts: [ArtifactReference]
    var artifactScope: ArtifactScope
    var selectedArtifactID: String?
    var route: ArtifactDockRoute
    var displayState: ArtifactViewerDisplayState
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
    var onOpenExternal: (URL) -> Void

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
            switch model.displayState {
            case .noCurrentSession:
                selectorStatus("No current session.", detail: "Select a running session in the tracker.")
            case .empty:
                selectorStatus("No artifacts.", detail: "Run qm artifact add from this session.")
            case .missing, .unsupported, .viewing:
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.artifacts) { artifact in
                            ArtifactRow(
                                artifact: artifact,
                                scope: model.artifactScope,
                                selected: artifact.id == model.selectedArtifactID,
                                action: { onSelectArtifact(artifact.id) }
                            )
                        }
                    }
                    .padding(Token.Spacing.card)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.artifactListColumn.swiftUI)
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
                .help(scope.title)
                .accessibilityLabel(scope.title)
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
}

private struct ArtifactRow: View {
    var artifact: ArtifactReference
    var scope: ArtifactScope
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
                    Text(artifact.path)
                        .font(AppFonts.monoSmall.swiftUI)
                        .foregroundStyle(AppPalette.dim.swiftUI)
                        .lineLimit(1)
                    if scope != .session, !artifact.sessionID.isEmpty {
                        Text(artifact.sessionID)
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.muted.swiftUI)
                            .lineLimit(1)
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
            return "doc"
        case .markdown:
            return "doc.richtext"
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
