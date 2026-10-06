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

/// The window's whole content view: the tracker/terminal split, the dock (full window height,
/// as before the action bar footer existed), and the footer (full window width, pinned to the
/// bottom, never resized or moved by either side card). Toggling the tracker only resizes
/// `splitView`'s own panes; the dock and footer are independent of it and of each other.
final class ShellRootContainerView: NSView {
    private let splitView: MainSplitView

    init(splitView: MainSplitView, footer: NSView) {
        self.splitView = splitView
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

        // Z-order, bottom to top: splitView, the dock (+ its resize divider), footer. Moves the
        // dock here so it can reach the window's full height instead of stopping above the
        // footer. At narrow windows or with a wide dock, the dock's bottom-right corner can land
        // under the footer's own area; the user hasn't decided which should win there — see the
        // single `position` line in `relocateDockToFullHeightSuperview` to flip it.
        splitView.relocateDockToFullHeightSuperview(self, below: footer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The dock's full-height frame (`MainSplitView.dockFrameSpanningFullHeight`) reads this
    /// view's own `bounds.height` as the window's real height. That's only authoritative once
    /// Auto Layout has actually sized this view, so re-run the dock/tracker/terminal layout pass
    /// every time this container itself lays out — tied to the one event guaranteed to happen
    /// after that sizing, rather than to `MainSplitView`'s own layout cycle, which can run first.
    override func layout() {
        super.layout()
        splitView.applyCanonicalLayout()
    }
}
