import AppKit

extension NSWindow {
    /// The system titlebar's own height, even with `fullSizeContentView` set (where
    /// `frame.height - contentLayoutRect.height` is otherwise the only place it's still
    /// visible). Used to size the terminal's window-drag strip so it reaches exactly as far as
    /// the titlebar it's standing in for, no more, no less.
    var titlebarHeight: CGFloat {
        frame.height - contentLayoutRect.height
    }
}

/// The window's whole content view: `splitView` (tracker, terminal, and the dock — the dock
/// reserves no space for the footer and keeps the window's full height, via
/// `ShellSplitLayoutMetrics.footerReservedHeight`) filling the window, with the footer pinned to
/// the bottom on top of it in z-order. The footer never resizes or repositions when the tracker
/// or dock change; where it and the dock's bottom corner actually overlap (a narrow window or a
/// wide dock), the footer wins by being the later `addSubview` call below — swap the two calls'
/// order to have the dock win there instead.
final class ShellRootContainerView: NSView {
    /// The footer's plate always keeps the shell gap above the window's bottom edge, plus the terminal
    /// row-snap leftover, which lands below the footer instead of inside the terminal pane. The leftover
    /// is zero until a Ghostty surface reports a cell size.
    private var footerBottomConstraint: NSLayoutConstraint!

    init(splitView: MainSplitView, footer: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.window.cgColor

        splitView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerBottomConstraint = footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(ShellMetrics.footerBand.plateBottomInset(snapLeftover: 0)))
        addSubview(splitView)
        addSubview(footer)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerBottomConstraint,
            footer.heightAnchor.constraint(equalToConstant: ActionBarMetrics.plateArtHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Covers the whole window above the split and the footer (the Quest Log modal).
    func addOverlay(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func setFooterBottomInset(_ inset: CGFloat) {
        footerBottomConstraint.constant = -CGFloat(ShellMetrics.footerBand.plateBottomInset(snapLeftover: Double(inset)))
    }
}
