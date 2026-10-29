import AppKit

/// The window's whole content view: `splitView` (tracker, the action bar header over the terminal,
/// the terminal, and the dock) filling the window, with room for overlays above it.
final class ShellRootContainerView: NSView {
    init(splitView: MainSplitView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.window.cgColor

        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Covers the whole window above the split (the Quest Log modal).
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
}
