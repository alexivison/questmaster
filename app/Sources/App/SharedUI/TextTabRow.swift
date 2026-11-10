import QuestmasterCore
import AppKit
import SwiftUI

/// Geometry of a text tab row (`Tabs (Simple).svg`): JetBrains Mono 12pt, and `Space.row` on each side of the 2 x 2
/// square turned 45° between the tabs. A 12pt line is 16 high, more than `ControlHeight.chip` holds, so the row is
/// `ControlHeight.compact` high with the line centred: its baseline 17 down. Measured from the user's mock (at 10pt),
/// the separator's centre sits 4.8 over the baseline.
enum TextTabMetrics {
    static let height = ControlHeight.compact
    static let separatorGap = Space.row
    static let labelBaseline: CGFloat = 17
    /// The separator's 2 x 2 square is 2.83 across once turned, its centre 4.8 over the baseline: the design's 4 at 10pt,
    /// scaled to 12.
    static let svgDiamondDiagonal: CGFloat = 2.83
    static let svgDiamondRaise: CGFloat = 4.8
    static let svgDiamondTop = labelBaseline - svgDiamondRaise - svgDiamondDiagonal / 2
    /// How far a clipped side fades out.
    static let fadeWidth = Space.section
    /// Tabs hang past a side by more than this, in points, before that side counts as clipped.
    static let hiddenTolerance: CGFloat = 0.5
}

/// A row of text tabs with a diamond between each pair. A row wider than its frame scrolls sideways with no scroller,
/// and a side with hidden tabs fades out. The selection scrolls to the middle when it changes, so the selected tab is
/// never left under a fade. The Worker Log and the Quest Log both use it.
struct TextTabRow: View {
    let titles: [String]
    /// The selected tab's index in `titles`.
    let selectedIndex: Int
    /// Whether the panel has the keys, which a selected tab's label follows.
    let areaFocused: Bool
    /// The tab under the pointer, for the renders.
    var previewHoveredIndex: Int?
    /// Where the tabs sit when they are narrower than the row.
    var alignment: Alignment = .center
    let onSelect: (Int) -> Void

    @State private var hiddenSides = TextTabHiddenSides()

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                            if index > 0 {
                                TextTabSeparator()
                            }
                            TextTab(
                                title: title,
                                selected: index == selectedIndex,
                                areaFocused: areaFocused,
                                previewHovered: index == previewHoveredIndex,
                                onSelect: { onSelect(index) }
                            )
                            .id(index)
                        }
                    }
                    .frame(minWidth: viewport.size.width, alignment: alignment)
                    .background(ScrollerHider())
                    .background(TextTabScrollWatcher { hiddenSides = $0 })
                }
                .scrollIndicators(.hidden)
                .onAppear { reveal(with: proxy) }
                .onChange(of: selectedIndex) { reveal(with: proxy) }
                .mask { edgeFades }
            }
        }
        .frame(height: TextTabMetrics.height)
    }

    private func reveal(with proxy: ScrollViewProxy) {
        guard titles.indices.contains(selectedIndex) else {
            return
        }
        proxy.scrollTo(selectedIndex, anchor: .center)
    }

    /// Opaque, with a fade at each end that has tabs hidden past it.
    private var edgeFades: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [hiddenSides.leading ? .clear : AppPalette.mask.swiftUI, AppPalette.mask.swiftUI], startPoint: .leading, endPoint: .trailing)
                .frame(width: TextTabMetrics.fadeWidth)
            AppPalette.mask.swiftUI
            LinearGradient(colors: [AppPalette.mask.swiftUI, hiddenSides.trailing ? .clear : AppPalette.mask.swiftUI], startPoint: .leading, endPoint: .trailing)
                .frame(width: TextTabMetrics.fadeWidth)
        }
    }
}

/// The sides of the tab row that have tabs scrolled out of view.
private struct TextTabHiddenSides: Equatable {
    var leading = false
    var trailing = false
}

/// Reports which sides of the enclosing scroll view have content scrolled out of view, from its clip view's bounds. Every
/// kind of scroll (trackpad, `scrollTo`, a resize) changes them, so nothing runs per frame. SwiftUI's own coordinate
/// spaces don't reach into a macOS scroll view's content, which is why this reads AppKit.
private struct TextTabScrollWatcher: NSViewRepresentable {
    let onChange: (TextTabHiddenSides) -> Void

    func makeNSView(context: Context) -> TextTabScrollWatcherView {
        TextTabScrollWatcherView()
    }

    func updateNSView(_ view: TextTabScrollWatcherView, context: Context) {
        view.onChange = onChange
    }
}

private final class TextTabScrollWatcherView: NSView {
    var onChange: ((TextTabHiddenSides) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var reported: TextTabHiddenSides?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard window != nil, let scrollView = enclosingScrollView, let documentView = scrollView.documentView else {
            return
        }
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        documentView.postsFrameChangedNotifications = true
        let sources: [(Notification.Name, NSView)] = [
            (NSView.boundsDidChangeNotification, clipView),
            (NSView.frameDidChangeNotification, clipView),
            (NSView.frameDidChangeNotification, documentView),
        ]
        observers = sources.map { name, view in
            NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        // Not inline: this runs inside a SwiftUI update, which must not change state.
        DispatchQueue.main.async { [weak self] in
            self?.report()
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func report() {
        guard let scrollView = enclosingScrollView, let documentView = scrollView.documentView else {
            return
        }
        let clip = scrollView.contentView.bounds
        let sides = TextTabHiddenSides(
            leading: clip.minX > TextTabMetrics.hiddenTolerance,
            trailing: documentView.bounds.width - clip.maxX > TextTabMetrics.hiddenTolerance
        )
        guard sides != reported else {
            return
        }
        reported = sides
        onChange?(sides)
    }
}

/// One tab: its label in a `TextTabLook`, centred on the row's baseline. A click selects it.
private struct TextTab: View {
    let title: String
    let selected: Bool
    let areaFocused: Bool
    let previewHovered: Bool
    let onSelect: () -> Void

    @State private var pointerOver = false

    var body: some View {
        let look = TextTabLook.tab(selected: selected, areaFocused: areaFocused, underPointer: pointerOver || previewHovered)
        BaselineText(title, font: look.bold ? AppFonts.workerTabSelected : AppFonts.workerTab, color: look.label.color, baseline: TextTabMetrics.labelBaseline)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: TextTabMetrics.height)
            .contentShape(Rectangle())
            .onHover { pointerOver = $0 }
            .onTapGesture(perform: onSelect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The diamond between two tabs: the design's #444C56, now the `line` colour #474F59.
private struct TextTabSeparator: View {
    var body: some View {
        Color.clear
            .frame(width: TextTabMetrics.svgDiamondDiagonal, height: TextTabMetrics.height)
            .overlay(alignment: .top) {
                DiamondShape()
                    .fill(AppPalette.line.swiftUI)
                    .frame(width: TextTabMetrics.svgDiamondDiagonal, height: TextTabMetrics.svgDiamondDiagonal)
                    .padding(.top, TextTabMetrics.svgDiamondTop)
            }
            .padding(.horizontal, TextTabMetrics.separatorGap)
            .accessibilityHidden(true)
    }
}
