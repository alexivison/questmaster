import AppKit
import QuestmasterCore
import SwiftUI

/// Geometry from `Tabs (Simple).svg`, as the user then set it: JetBrains Mono 12pt, the feed's chat font (7.2 advance,
/// 8.8 cap height), and `Space.row` on each side of the 2 x 2 square turned 45° between the tabs. A 12pt line is 16 high,
/// more than `ControlHeight.chip` holds, so the row is `ControlHeight.compact` high with the line centred: its baseline 17
/// down. The feed ends where the row begins, and the row ends `bottomInset` above the panel's bottom edge. Measured from the
/// user's mock (at 10pt), the last feed line's ink was 32 over the tabs' and their baseline 20 over the edge; this lands on
/// 30.5 and 18.
enum WorkerLogTabMetrics {
    static let height = ControlHeight.compact
    static let bottomInset = Space.item
    /// What the row takes from the panel's bottom: the row and the inset under it.
    static let reserved = height + bottomInset
    static let separatorGap = Space.row
    /// The scroller's inset from the panel's edges: the bottom corners' scoop reaches its radius in beside the row, and
    /// the tabs, clipped or not, keep `Space.item` clear of it. A row that fits is centred between the insets.
    static let sideInset = ScoopedRectangle.radius + Space.item
    /// How far a clipped side fades out, as the feed's top does.
    static let fadeWidth = WorkerChatMetrics.topFadeHeight
    static let labelBaseline: CGFloat = 17
    /// The separator's 2 x 2 square is 2.83 across once turned, its centre 4.8 over the baseline: the design's 4 at 10pt,
    /// scaled to 12.
    static let svgDiamondDiagonal: CGFloat = 2.83
    static let svgDiamondRaise: CGFloat = 4.8
    static let svgDiamondTop = labelBaseline - svgDiamondRaise - svgDiamondDiagonal / 2
    /// Tabs hang past a side by more than this, in points, before that side counts as clipped.
    static let hiddenTolerance: CGFloat = 0.5
}

/// The Worker Log's tabs: All, then one per worker in the tracker's order, pinned under the feed. A row that is wider
/// than the panel scrolls sideways with no scroller, and a side with hidden tabs fades out. The selection scrolls to the
/// middle when it changes, so the selected tab is never left under a fade.
struct WorkerLogTabRow: View {
    let workers: [WorkerLogWorker]
    /// The selected worker's id; nil selects All.
    let selectedID: String?
    /// Whether the panel has the keys, which a selected tab's label follows.
    let areaFocused: Bool
    /// The tab under the pointer, for the renders.
    var previewHoveredIndex: Int?
    let onSelect: (String?) -> Void

    @State private var hiddenSides = WorkerLogTabHiddenSides()

    /// The tab at each index is All, then the workers.
    private var tabs: [(workerID: String?, title: String)] {
        [(nil, "All")] + workers.map { ($0.id, $0.name) }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                            if index > 0 {
                                WorkerLogTabSeparator()
                            }
                            WorkerLogTab(
                                title: tab.title,
                                selected: tab.workerID == selectedID,
                                areaFocused: areaFocused,
                                previewHovered: index == previewHoveredIndex,
                                onSelect: { onSelect(tab.workerID) }
                            )
                            .id(index)
                        }
                    }
                    .frame(minWidth: viewport.size.width)
                    .background(ScrollerHider())
                    .background(WorkerLogTabScrollWatcher { hiddenSides = $0 })
                }
                .scrollIndicators(.hidden)
                .onAppear { reveal(with: proxy) }
                .onChange(of: selectedID) { reveal(with: proxy) }
                .mask { edgeFades }
            }
        }
        .frame(height: WorkerLogTabMetrics.height)
    }

    private func reveal(with proxy: ScrollViewProxy) {
        guard let index = tabs.firstIndex(where: { $0.workerID == selectedID }) else {
            return
        }
        proxy.scrollTo(index, anchor: .center)
    }

    /// Opaque, with a fade at each end that has tabs hidden past it.
    private var edgeFades: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [hiddenSides.leading ? .clear : AppPalette.mask.swiftUI, AppPalette.mask.swiftUI], startPoint: .leading, endPoint: .trailing)
                .frame(width: WorkerLogTabMetrics.fadeWidth)
            AppPalette.mask.swiftUI
            LinearGradient(colors: [AppPalette.mask.swiftUI, hiddenSides.trailing ? .clear : AppPalette.mask.swiftUI], startPoint: .leading, endPoint: .trailing)
                .frame(width: WorkerLogTabMetrics.fadeWidth)
        }
    }
}

/// The sides of the tab row that have tabs scrolled out of view.
private struct WorkerLogTabHiddenSides: Equatable {
    var leading = false
    var trailing = false
}

/// Reports which sides of the enclosing scroll view have content scrolled out of view, from its clip view's bounds. Every
/// kind of scroll (trackpad, `scrollTo`, a resize) changes them, so nothing runs per frame. SwiftUI's own coordinate
/// spaces don't reach into a macOS scroll view's content, which is why this reads AppKit.
private struct WorkerLogTabScrollWatcher: NSViewRepresentable {
    let onChange: (WorkerLogTabHiddenSides) -> Void

    func makeNSView(context: Context) -> WorkerLogTabScrollWatcherView {
        WorkerLogTabScrollWatcherView()
    }

    func updateNSView(_ view: WorkerLogTabScrollWatcherView, context: Context) {
        view.onChange = onChange
    }
}

private final class WorkerLogTabScrollWatcherView: NSView {
    var onChange: ((WorkerLogTabHiddenSides) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var reported: WorkerLogTabHiddenSides?

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
        let sides = WorkerLogTabHiddenSides(
            leading: clip.minX > WorkerLogTabMetrics.hiddenTolerance,
            trailing: documentView.bounds.width - clip.maxX > WorkerLogTabMetrics.hiddenTolerance
        )
        guard sides != reported else {
            return
        }
        reported = sides
        onChange?(sides)
    }
}

/// One tab: its label in a `TextTabLook`, centred on the row's baseline. A click selects it.
private struct WorkerLogTab: View {
    let title: String
    let selected: Bool
    let areaFocused: Bool
    let previewHovered: Bool
    let onSelect: () -> Void

    @State private var pointerOver = false

    var body: some View {
        let look = TextTabLook.tab(selected: selected, areaFocused: areaFocused, underPointer: pointerOver || previewHovered)
        BaselineText(title, font: font(for: look), color: look.label.color, baseline: WorkerLogTabMetrics.labelBaseline)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: WorkerLogTabMetrics.height)
            .contentShape(Rectangle())
            .onHover { pointerOver = $0 }
            .onTapGesture(perform: onSelect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func font(for look: TextTabLook) -> NSFont {
        look.bold ? AppFonts.workerTabSelected : AppFonts.workerTab
    }
}

/// The diamond between two tabs: the design's #444C56, now the `line` colour #474F59.
private struct WorkerLogTabSeparator: View {
    var body: some View {
        Color.clear
            .frame(width: WorkerLogTabMetrics.svgDiamondDiagonal, height: WorkerLogTabMetrics.height)
            .overlay(alignment: .top) {
                DiamondShape()
                    .fill(AppPalette.line.swiftUI)
                    .frame(width: WorkerLogTabMetrics.svgDiamondDiagonal, height: WorkerLogTabMetrics.svgDiamondDiagonal)
                    .padding(.top, WorkerLogTabMetrics.svgDiamondTop)
            }
            .padding(.horizontal, WorkerLogTabMetrics.separatorGap)
            .accessibilityHidden(true)
    }
}
