import AppKit

/// A glyph the app draws: a decided icon, or an SF Symbol for a place no icon has been decided for yet. Each caller draws an
/// SF Symbol at the size it always has.
enum AppGlyph {
    case symbol(String)
    case icon(AppIcon)
}

/// The decided "fantasy line" icons: one case per drawing. The SVGs in `Resources/Icons/line` (39) and `Resources/Icons/filled`
/// (30) are the source of truth, bundled unchanged. Each is 24 units with a 1.5 stroke, round caps and joins, `#000000` for
/// ink and `#ffffff` for a knock-out that shows the tile through. The raw value is the drawing's file name.
///
/// Keylines, so the set reads at one size like the SF Symbols: a round shape fills a 20-unit circle (cog, globe), a square-ish
/// one an 18 box, a tall one is 20 high, a wide one 20 wide, and a bare stroke (cross, back arrow) 16. Shapes are not redrawn
/// to fit; only scale and centring move. A new drawing follows the same rule, with the stroke kept at 1.5.
///
/// A drawing is read as a coverage mask rather than as colour: ink is opaque, a knock-out and the space around the glyph are
/// clear. `image` fills only the ink, so one cached mask serves every tint, as a template image would. The mask is rasterised
/// on the glyph's device pixel grid, so a glyph at 1x sits on whole pixels, and its stroke scales with it (1.5 per 24).
enum AppIcon: String, CaseIterable {
    // The action bar. Each one also has a filled drawing, which a button that is on draws.
    case trackerBanner = "tracker-banner"
    case newSessionHelm = "new-session-helm"
    case questLogScroll = "quest-log-scroll"
    case newQuestScrollQuill = "new-quest-scroll-quill"
    case settingsCog = "settings-cog"
    case artifactsBedrollPack = "artifacts-bedroll-pack"
    case workerLogConversation = "worker-log-conversation"
    case watcherEye = "watcher-eye"
    case keepAwakeBolt = "keep-awake-bolt"
    // The tracker's cast squares, one per kind of tool. `TrackerCast.iconName` names them.
    case castShellWand = "cast-shell-wand"
    case castEditQuill = "cast-edit-quill"
    case castReadCrystalBall = "cast-read-crystal-ball"
    case castWebGlobe = "cast-web-globe"
    case castSubagentAllies = "cast-subagent-allies"
    case castTodoInkwell = "cast-todo-inkwell"
    case castOtherSpanner = "cast-other-spanner"
    // The tracker's discs: the shell's and an agent the app doesn't know.
    case discShellTerminal = "disc-shell-terminal"
    case discUnknownMask = "disc-unknown-mask"
    case settingsModelsBrain = "settings-models-brain"
    case settingsProjectsFolder = "settings-projects-folder"
    // The Projects page: the header's arrange, save and add, a row's move arrows, and the folder row's add.
    case settingsArrangeArrows = "settings-arrange-arrows"
    case settingsSaveCheck = "settings-save-check"
    case settingsAddPlus = "settings-add-plus"
    case rowMoveUp = "row-move-up"
    case rowMoveDown = "row-move-down"
    // The dock's top bars.
    case dockFilterFunnel = "dock-filter-funnel"
    case dockCloseCross = "dock-close-cross"
    case dockBackArrow = "dock-back-arrow"
    case dockCopyPapers = "dock-copy-papers"
    case dockRefreshCycle = "dock-refresh-cycle"
    // The artifact list's kinds and marks, and the status panes.
    case artifactHTMLTome = "artifact-html-tome"
    case artifactMarkdownNotebook = "artifact-markdown-notebook"
    case artifactImagePortrait = "artifact-image-portrait"
    case artifactUnsupportedQuestion = "artifact-unsupported-question"
    case artifactMissingHazard = "artifact-missing-hazard"
    case artifactBlockedShield = "artifact-blocked-shield"
    case artifactDeleteMarkDiamond = "artifact-delete-mark-diamond"
    // The empty states: the moon when nothing is there yet, the shrug when a filter hid everything.
    case emptyIdleMoon = "empty-idle-moon"
    case emptyNoMatchShrug = "empty-no-match-shrug"

    /// The glyphs with no filled drawing: the dock's close, back and refresh, the Projects page's five, and the viewer's shield.
    private static let lineOnly: Set<AppIcon> = [
        .dockCloseCross, .dockBackArrow, .dockRefreshCycle,
        .settingsArrangeArrows, .settingsSaveCheck, .settingsAddPlus, .rowMoveUp, .rowMoveDown,
        .artifactBlockedShield,
    ]
    private static let bundle = AppSymbolStyle.resourceBundle()
    private static let masks = NSCache<NSString, CGImage>()

    /// Whether the glyph has a filled drawing. A filled request for one that doesn't draws the line drawing.
    var hasFilled: Bool { !Self.lineOnly.contains(self) }

    /// The bundled SVG of the line or the filled drawing, nil when the bundle lacks it.
    func url(filled: Bool) -> URL? {
        Self.bundle.url(forResource: rawValue, withExtension: "svg", subdirectory: filled ? "Icons/filled" : "Icons/line")
    }

    /// The glyph tinted `tint`, as a square of `glyphSide` points centred in a `canvasSide` square (the glyph's own square when
    /// there is no canvas). `filled` draws the filled drawing, for a button that is on, where the glyph has one.
    func image(glyphSide: CGFloat, canvasSide: CGFloat? = nil, tint: NSColor, filled: Bool = false) -> NSImage? {
        let drawsFilled = filled && hasFilled
        guard url(filled: drawsFilled) != nil else {
            return nil
        }
        let canvas = canvasSide ?? glyphSide
        let image = NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }
            let scale = AppSymbolStyle.currentBackingScale()
            let glyphRect = AppSymbolStyle.pixelAligned(
                NSRect(x: rect.midX - glyphSide / 2, y: rect.midY - glyphSide / 2, width: glyphSide, height: glyphSide),
                scale: scale
            )
            guard let mask = Self.mask(self, filled: drawsFilled, pixels: Int((glyphRect.width * scale).rounded())) else {
                return false
            }
            context.saveGState()
            context.clip(to: glyphRect, mask: mask)
            tint.setFill()
            glyphRect.fill()
            context.restoreGState()
            return true
        }
        image.isTemplate = false
        image.cacheMode = .never
        image.alignmentRect = NSRect(origin: .zero, size: NSSize(width: canvas, height: canvas))
        return image
    }

    /// The drawing as a coverage mask `pixels` square. It is rasterised over an opaque white page, so the ink reads black and
    /// the knock-outs and the space around the glyph read white. An image mask paints where its sample is 0, so the page's
    /// grey level is the mask as it stands: ink paints, white is clear, and antialiased edges keep their partial coverage.
    /// (An SVG rep draws nothing into a grey-only context, so the page is RGBA and its red channel, equal to its grey, is kept.)
    private static func mask(_ icon: AppIcon, filled: Bool, pixels: Int) -> CGImage? {
        guard pixels > 0 else {
            return nil
        }
        let key = "\(icon.rawValue)-\(filled ? "filled" : "line")@\(pixels)" as NSString
        if let cached = masks.object(forKey: key) {
            return cached
        }
        guard let url = icon.url(filled: filled),
              let source = NSImage(contentsOf: url),
              let page = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pageBytes = page.data else {
            return nil
        }
        page.setFillColor(gray: 1, alpha: 1)
        page.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: page, flipped: false)
        source.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
        // The page is opaque, so its red channel is its grey level. `page` must outlive the read of its bytes.
        let grey = withExtendedLifetime(page) {
            Data((0..<(pixels * pixels)).map { pageBytes.load(fromByteOffset: $0 * 4, as: UInt8.self) })
        }
        guard let provider = CGDataProvider(data: grey as CFData),
              let mask = CGImage(
                  maskWidth: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: pixels,
                  provider: provider, decode: nil, shouldInterpolate: true
              ) else {
            return nil
        }
        masks.setObject(mask, forKey: key)
        return mask
    }
}
