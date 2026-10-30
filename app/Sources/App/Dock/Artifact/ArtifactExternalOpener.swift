import AppKit
import QuestmasterCore

enum ArtifactExternalRoute: Equatable {
    case editor
    case browser
    case preview
    case system

    static func classify(path: String) -> Self {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "md", "markdown": .editor
        case "html", "htm": .browser
        case "png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "webp", "bmp", "svg": .preview
        default: .system
        }
    }
}

enum ArtifactExternalOpenError: LocalizedError {
    case missingFile(String)
    case missingSession
    case missingTmux
    case unavailableApplication(String)
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let path): "Artifact file is missing: \(path)"
        case .missingSession: "Attach a session to open Markdown in its terminal."
        case .missingTmux: "tmux is unavailable; install it to open Markdown in the attached session."
        case .unavailableApplication(let name): "\(name) is unavailable."
        case .openFailed(let path): "Could not open artifact: \(path)"
        }
    }
}

enum ArtifactExternalOpener {
    static func open(
        artifact: ArtifactReference,
        attachedSessionID: String?,
        tmuxPath: String?,
        environment: [String: String]
    ) throws {
        let path = artifact.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ArtifactExternalOpenError.missingFile(path)
        }
        let url = URL(fileURLWithPath: path)
        switch ArtifactExternalRoute.classify(path: path) {
        case .editor:
            guard let attachedSessionID, !attachedSessionID.isEmpty else {
                throw ArtifactExternalOpenError.missingSession
            }
            guard let tmuxPath else {
                throw ArtifactExternalOpenError.missingTmux
            }
            try TerminalTmuxClientProcess.openEditorWindow(
                tmuxPath: tmuxPath,
                sessionID: attachedSessionID,
                path: path,
                shell: environment["SHELL"] ?? "/bin/zsh",
                environment: environment
            )
        case .browser:
            let webURL = URL(string: "https://localhost/")!
            guard let browser = NSWorkspace.shared.urlForApplication(toOpen: webURL) else {
                throw ArtifactExternalOpenError.unavailableApplication("Browser")
            }
            open(url, with: browser)
        case .preview:
            guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                throw ArtifactExternalOpenError.unavailableApplication("Preview")
            }
            open(url, with: preview)
        case .system:
            guard NSWorkspace.shared.open(url) else {
                throw ArtifactExternalOpenError.openFailed(path)
            }
        }
    }

    private static func open(_ url: URL, with application: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { _, error in
            if let error {
                Task { @MainActor in NSApp.presentError(error) }
            }
        }
    }
}
