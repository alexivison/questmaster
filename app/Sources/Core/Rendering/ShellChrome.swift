import Foundation

/// Pure presentation decisions for the shell top-bar chrome (dock back-targets,
/// serve-status pill). Colors/fonts stay in the app token
/// layer; this file only decides *what* the chrome shows, keyed off
/// UI-independent state, so both the decision and its edge cases stay testable.

/// What content the dock pane is showing.
public enum DockContentMode: Equatable {
    case artifacts
    case quests
}

/// Where the artifact area of the dock currently is.
public enum ArtifactDockRoute: Equatable {
    case list
    case viewer
}

/// Fully resolved dock top-bar layout: which back affordance (if any), the
/// optional title, and whether an artifact's actions show.
public struct DockTopBarModel: Equatable {
    public enum Back: Equatable {
        case artifactList
    }

    public let back: Back?
    public let title: String?
    public let showArtifactActions: Bool

    public init(
        back: Back?,
        title: String?,
        showArtifactActions: Bool
    ) {
        self.back = back
        self.title = title
        self.showArtifactActions = showArtifactActions
    }

    public static func make(
        mode: DockContentMode,
        artifactRoute: ArtifactDockRoute,
        artifactTitle: String?
    ) -> DockTopBarModel {
        let viewingArtifact = mode == .artifacts && artifactRoute == .viewer
        return DockTopBarModel(
            back: viewingArtifact ? .artifactList : nil,
            title: mode == .quests ? "Quests" : (viewingArtifact ? (artifactTitle ?? "Artifact") : "Artifacts"),
            showArtifactActions: viewingArtifact
        )
    }
}

/// The serve-status pill's text + indicator. The pill's colors are derived from
/// `ServeConnectionState` in the app token layer; this only fixes the copy and
/// whether the indicator is a static dot or an animated spinner.
public struct ServePillDisplay: Equatable {
    public enum Indicator: Equatable {
        case dot
        case spinner
    }

    public let label: String
    public let indicator: Indicator

    public init(label: String, indicator: Indicator) {
        self.label = label
        self.indicator = indicator
    }

    public static func make(_ state: ServeConnectionState) -> ServePillDisplay {
        switch state {
        case .ready:
            return ServePillDisplay(label: "serve", indicator: .dot)
        case .starting:
            return ServePillDisplay(label: "starting serve…", indicator: .spinner)
        case .error:
            return ServePillDisplay(label: "serve error", indicator: .dot)
        }
    }
}
