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

/// The window's whole content view: the three-pane split above a full-width action bar footer.
/// Toggling the tracker or dock only resizes `splitView`'s own panes — the footer, pinned to the
/// container's bottom edge, never moves.
final class ShellRootContainerView: NSView {
    init(splitView: NSView, footer: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.window.cgColor

        splitView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)
        addSubview(footer)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: ActionBarMetrics.footerHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
