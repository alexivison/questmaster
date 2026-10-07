import Foundation

public enum RightDockWidthMode: Equatable {
    case standard
    case compact
}

public struct ShellSplitLayoutMetrics: Equatable {
    /// Vertical inset for the tracker/dock side cards, and the horizontal gap on the dock's
    /// outer (window-facing) edge only — its terminal-facing edge sits flush, with Ghostty's own
    /// padding providing the visible gap there. The tracker's own horizontal gaps are
    /// `trackerLeadingInset`/`trackerTrailingGap` below, so its two sides can differ from the dock's.
    public let sideCardInset: Double
    public let dockDividerHitWidth: Double
    public let trackerMaxWidth: Double
    /// Window edge to the tracker plates.
    public let trackerLeadingInset: Double
    /// Tracker plates to the terminal pane — 0 when Ghostty's own horizontal padding already
    /// reaches `G` on its own, otherwise the shortfall (`ShellGapDerivation.flushGap`).
    public let trackerTrailingGap: Double
    /// Terminal pane to the dock's inner (terminal-facing) edge when the dock is visible, or to
    /// the window's trailing edge when it's hidden — same derivation as `trackerTrailingGap`, on
    /// the same axis, so all three stay equal.
    public let terminalToDockGap: Double
    /// Terminal pane to the window's top edge — the vertical analogue of `terminalToDockGap`.
    /// The tracker and dock don't use this: they already reach the top via `sideCardInset`.
    public let terminalTopInset: Double
    /// Height reserved at the window's bottom for a footer drawn outside this layout (the action
    /// bar) — only the terminal frame stops above it. The tracker, like the dock, keeps the full
    /// window height with `sideCardInset` top and bottom regardless of the footer; both are drawn
    /// over by it where it overlaps, rather than sharing space with it.
    public let footerReservedHeight: Double

    public init(
        sideCardInset: Double,
        dockDividerHitWidth: Double,
        trackerMaxWidth: Double,
        trackerLeadingInset: Double,
        trackerTrailingGap: Double,
        terminalToDockGap: Double = 0,
        terminalTopInset: Double = 0,
        footerReservedHeight: Double = 0
    ) {
        self.sideCardInset = sideCardInset
        self.dockDividerHitWidth = dockDividerHitWidth
        self.trackerMaxWidth = trackerMaxWidth
        self.trackerLeadingInset = trackerLeadingInset
        self.trackerTrailingGap = trackerTrailingGap
        self.terminalToDockGap = terminalToDockGap
        self.terminalTopInset = terminalTopInset
        self.footerReservedHeight = footerReservedHeight
    }
}

public struct ShellSplitSize: Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct ShellSplitRect: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double {
        x + width
    }

    public var maxY: Double {
        y + height
    }

    public var midX: Double {
        x + width / 2
    }

    public var midY: Double {
        y + height / 2
    }

    public var isWholePoint: Bool {
        [x, y, width, height].allSatisfy { $0.rounded() == $0 }
    }
}

public struct ShellSplitLayout: Equatable {
    public let trackerFrame: ShellSplitRect
    public let terminalFrame: ShellSplitRect
    public let dockFrame: ShellSplitRect
    public let firstDividerFrame: ShellSplitRect
    public let secondDividerFrame: ShellSplitRect
    public let dockWidth: Double

    public init(
        trackerFrame: ShellSplitRect,
        terminalFrame: ShellSplitRect,
        dockFrame: ShellSplitRect,
        firstDividerFrame: ShellSplitRect,
        secondDividerFrame: ShellSplitRect,
        dockWidth: Double
    ) {
        self.trackerFrame = trackerFrame
        self.terminalFrame = terminalFrame
        self.dockFrame = dockFrame
        self.firstDividerFrame = firstDividerFrame
        self.secondDividerFrame = secondDividerFrame
        self.dockWidth = dockWidth
    }
}

public enum ShellSplitLayoutPlanner {
    public static func layout(
        size: ShellSplitSize,
        metrics: ShellSplitLayoutMetrics,
        trackerVisible: Bool,
        dockVisible: Bool,
        preferredDockWidth: Double?,
        dockWidthMode: RightDockWidthMode
    ) -> ShellSplitLayout? {
        guard size.width > 0 else {
            return nil
        }

        let availableWidth = max(0, size.width - sideCardHorizontalInsets(
            metrics: metrics,
            trackerVisible: trackerVisible,
            dockVisible: dockVisible
        ))
        let trackerWidth = trackerVisible ? min(metrics.trackerMaxWidth, availableWidth) : 0
        let dockWidth = dockVisible
            ? DockWidthPreference.clampedWidth(
                proposedDockWidth(
                    preferredDockWidth: preferredDockWidth,
                    dockWidthMode: dockWidthMode,
                    windowWidth: size.width
                ),
                availableWidth: availableWidth,
                trackerWidth: trackerWidth
            )
            : 0
        let terminalWidth = max(0, availableWidth - trackerWidth - dockWidth)

        // NSView frames are non-flipped (y=0 is the window's bottom edge, so a rect's `y` is its
        // BOTTOM edge, and only `height` controls where its top edge lands). The tracker, like
        // the dock, reaches the full window height via `sideCardInset` top and bottom, regardless
        // of the footer reservation — only the terminal's own bottom edge stops above it, fixed at
        // `paneAreaY`. `terminalTopInset` pulls its TOP edge down from the window's top by
        // shortening `paneAreaHeight` alone (leaving `paneAreaY` — the bottom edge — untouched),
        // the same way `terminalToDockGap` pulls its trailing edge in from the dock (or the
        // window's edge, dock hidden) by shortening its width, not moving its leading edge.
        let paneAreaY = metrics.footerReservedHeight
        let paneAreaHeight = max(0, size.height - metrics.footerReservedHeight - metrics.terminalTopInset)
        let sideCardY = metrics.sideCardInset
        let sideCardHeight = max(0, size.height - (metrics.sideCardInset * 2))
        var x = 0.0
        let trackerFrame: ShellSplitRect
        let firstDividerFrame: ShellSplitRect
        if trackerVisible {
            trackerFrame = ShellSplitRect(
                x: metrics.trackerLeadingInset,
                y: sideCardY,
                width: trackerWidth,
                height: sideCardHeight
            )
            x = trackerFrame.maxX + metrics.trackerTrailingGap
            firstDividerFrame = ShellSplitRect(x: trackerFrame.maxX, y: sideCardY, width: 0, height: sideCardHeight)
        } else {
            trackerFrame = ShellSplitRect(x: 0, y: sideCardY, width: 0, height: sideCardHeight)
            firstDividerFrame = ShellSplitRect(x: 0, y: 0, width: 0, height: 0)
        }

        let terminalFrame = ShellSplitRect(x: x, y: paneAreaY, width: terminalWidth, height: paneAreaHeight)
        x += terminalWidth

        let secondDividerFrame: ShellSplitRect
        let dockFrame: ShellSplitRect
        if dockVisible {
            // `terminalToDockGap` is 0 (flush) whenever Ghostty's own padding already reaches
            // `G` on its own; `sideCardInset` only guards the dock's outer (window-facing) edge.
            let dockCardMinX = x + metrics.terminalToDockGap
            secondDividerFrame = ShellSplitRect(
                x: dockCardMinX - (metrics.dockDividerHitWidth / 2),
                y: sideCardY,
                width: metrics.dockDividerHitWidth,
                height: sideCardHeight
            )
            dockFrame = ShellSplitRect(
                x: dockCardMinX,
                y: sideCardY,
                width: dockWidth,
                height: sideCardHeight
            )
        } else {
            secondDividerFrame = ShellSplitRect(x: size.width, y: sideCardY, width: 0, height: sideCardHeight)
            dockFrame = ShellSplitRect(x: size.width, y: sideCardY, width: 0, height: sideCardHeight)
        }

        return ShellSplitLayout(
            trackerFrame: pointAligned(trackerFrame),
            terminalFrame: pointAligned(terminalFrame),
            dockFrame: pointAligned(dockFrame),
            firstDividerFrame: pointAligned(firstDividerFrame),
            secondDividerFrame: pointAligned(secondDividerFrame),
            dockWidth: pointAligned(dockWidth)
        )
    }

    public static func resizedDockWidth(
        startWidth: Double,
        deltaX: Double,
        windowWidth: Double,
        metrics: ShellSplitLayoutMetrics,
        trackerVisible: Bool,
        dockVisible: Bool
    ) -> Double {
        guard dockVisible else {
            return startWidth
        }
        let availableWidth = max(0, windowWidth - sideCardHorizontalInsets(
            metrics: metrics,
            trackerVisible: trackerVisible,
            dockVisible: dockVisible
        ))
        let trackerWidth = trackerVisible ? min(metrics.trackerMaxWidth, availableWidth) : 0
        return DockWidthPreference.clampedWidth(
            startWidth - deltaX,
            availableWidth: availableWidth,
            trackerWidth: trackerWidth
        )
    }

    private static func sideCardHorizontalInsets(
        metrics: ShellSplitLayoutMetrics,
        trackerVisible: Bool,
        dockVisible: Bool
    ) -> Double {
        let trackerInsets = trackerVisible ? metrics.trackerLeadingInset + metrics.trackerTrailingGap : 0
        // `terminalToDockGap` reserves the terminal's own trailing inset either way — against the
        // dock's inner edge when visible, or the window's trailing edge when it's hidden.
        // `sideCardInset` additionally guards the dock's outer (window-facing) edge, only when visible.
        let dockInsets = (dockVisible ? metrics.sideCardInset : 0) + metrics.terminalToDockGap
        return trackerInsets + dockInsets
    }

    private static func proposedDockWidth(
        preferredDockWidth: Double?,
        dockWidthMode: RightDockWidthMode,
        windowWidth: Double
    ) -> Double {
        switch dockWidthMode {
        case .standard:
            return preferredDockWidth ?? DockWidthPreference.defaultWidth(forWindowWidth: windowWidth)
        case .compact:
            return DockWidthPreference.compactWidth
        }
    }

    private static func pointAligned(_ rect: ShellSplitRect) -> ShellSplitRect {
        ShellSplitRect(
            x: pointAligned(rect.x),
            y: pointAligned(rect.y),
            width: pointAligned(rect.width),
            height: pointAligned(rect.height)
        )
    }

    private static func pointAligned(_ value: Double) -> Double {
        value.rounded()
    }
}
