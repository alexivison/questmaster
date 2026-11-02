import AppKit

/// A game-icons.net glyph (CC BY 3.0; CREDITS.md maps each file to its icon and author). Every glyph that isn't an SF
/// Symbol comes through here as an NSImage tinted to the caller's colour, so SwiftUI (`Image(nsImage:)`) and AppKit draw
/// the same thing. The raw value is the file's name, and names the glyph by its role. The files live in
/// `Resources/Icons`, but SwiftPM flattens `.process`ed resources into the bundle root, so the names must stay unique there.
enum AppIcon: String, CaseIterable {
    /// The action bar's tracker toggle.
    case trackerToggle = "tracker-toggle"
    /// The New Session button: the user's own glyph, derived from `trackerToggle`'s.
    case newSession = "new-session"
    case questLog = "quest-log"
    case newQuest = "new-quest"
    case settings
    case artifacts
    case workerLog = "worker-log"
    case versionControl = "version-control"
    case caffeinate
    /// The tracker's cast squares, one per kind of tool. `Core` names them (`TrackerCast.iconName`).
    case castShell = "cast-shell"
    case castEdit = "cast-edit"
    case castRead = "cast-read"
    case castWeb = "cast-web"
    case castTask = "cast-task"
    case castTodo = "cast-todo"
    case castTool = "cast-tool"
    /// A session whose agent the app doesn't know.
    case agentUnknown = "agent-unknown"
    case settingsModels = "settings-models"
    /// The empty state of a list that a filter emptied (`ListEmptyReason.noMatch`).
    case emptySearch = "empty-search"
    case filter
    case close
    case copyPath = "copy-path"
    case refresh
    case artifactHTML = "artifact-html"
    case artifactMarkdown = "artifact-markdown"
    case artifactImage = "artifact-image"
    case artifactUnsupported = "artifact-unsupported"
    case artifactMissing = "artifact-missing"

    private static let sources = NSCache<NSString, NSImage>()

    /// The glyph tinted `tint`, as a square of `glyphSide` points centred in a `canvasSide` square (the glyph's own
    /// square when there is no canvas).
    func image(glyphSide: CGFloat, canvasSide: CGFloat? = nil, tint: NSColor) -> NSImage? {
        guard let source = Self.source(named: rawValue) else {
            return nil
        }
        let canvas = canvasSide ?? glyphSide
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            let scale = AppSymbolStyle.currentBackingScale()
            let glyphRect = AppSymbolStyle.pixelAligned(
                NSRect(x: rect.midX - glyphSide / 2, y: rect.midY - glyphSide / 2, width: glyphSide, height: glyphSide),
                scale: scale
            )
            source.draw(
                in: glyphRect,
                from: NSRect(origin: .zero, size: source.size),
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            tint.setFill()
            glyphRect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        image.alignmentRect = NSRect(origin: .zero, size: NSSize(width: canvas, height: canvas))
        return image
    }

    /// The untinted SVG, read once: the glyphs are small, and the tracker draws them on every cast change.
    private static func source(named name: String) -> NSImage? {
        if let cached = sources.object(forKey: name as NSString) {
            return cached
        }
        guard let url = AppSymbolStyle.resourceBundle().url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        sources.setObject(image, forKey: name as NSString)
        return image
    }
}
