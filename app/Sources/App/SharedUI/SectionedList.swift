import AppKit
import QuestmasterCore
import SwiftUI

/// A request to scroll a row into view. `nonce` lets a caller force a fresh scroll even when `id`
/// repeats — e.g. `gg`/`G` landing back on the row that's already selected and scrolled off
/// screen, where `SectionedList`'s other triggers (`selectedID`, this same `id`) wouldn't change.
struct ScrollTarget: Equatable {
    var id: String
    var nonce: Int
}

struct SectionedList<Content: View>: View {
    let selectedID: String?
    var scrollOnAppear = false
    var scrollOnSelectionChange = true
    var scrollTarget: ScrollTarget?
    private let content: () -> Content
    @State private var scrollDebounceTask: Task<Void, Never>?

    init(
        selectedID: String?,
        scrollOnAppear: Bool = false,
        scrollOnSelectionChange: Bool = true,
        scrollTarget: ScrollTarget? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.selectedID = selectedID
        self.scrollOnAppear = scrollOnAppear
        self.scrollOnSelectionChange = scrollOnSelectionChange
        self.scrollTarget = scrollTarget
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.bottom, Space.row)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ScrollerHider())
            }
            .scrollIndicators(.hidden)
            .onAppear {
                guard scrollOnAppear else {
                    return
                }
                scrollSelected(with: proxy, id: selectedID)
            }
            .onChange(of: selectedID) { _, nextID in
                guard scrollOnSelectionChange else {
                    return
                }
                switch PointerHighlight.cursor.scrollStep(to: nextID) {
                case .scroll:
                    scheduleScroll(with: proxy, id: nextID)
                case .cancelQueued:
                    scrollDebounceTask?.cancel()
                }
            }
            .onChange(of: scrollTarget) { _, next in
                scheduleScroll(with: proxy, id: next?.id)
            }
        }
    }

    /// Rapid selection moves (e.g. holding an arrow key) each set a new target
    /// id; scrolling to every intermediate one queues up expensive LazyVStack
    /// reconciliation faster than it can complete, stalling the main thread.
    /// Debounce so only the final target of a burst actually scrolls.
    private func scheduleScroll(with proxy: ScrollViewProxy, id: String?) {
        scrollDebounceTask?.cancel()
        guard let id else {
            return
        }
        scrollDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else {
                return
            }
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func scrollSelected(with proxy: ScrollViewProxy, id: String?) {
        guard let id else {
            return
        }
        proxy.scrollTo(id, anchor: .center)
    }

}

/// Drop into any `ScrollView` via `.background(ScrollerHider())` to keep its enclosing
/// `NSScrollView` scroller forced hidden, including across a system scroller-style change.
struct ScrollerHider: NSViewRepresentable {
    var onApply: (NSScrollView) -> Void = hideScroller

    func makeNSView(context: Context) -> ScrollerHidingNSView {
        let view = ScrollerHidingNSView()
        view.onApply = onApply
        return view
    }

    func updateNSView(_ nsView: ScrollerHidingNSView, context: Context) {
        nsView.onApply = onApply
        DispatchQueue.main.async {
            nsView.reapply()
        }
    }
}

/// An invisible view that keeps its enclosing `NSScrollView`'s scroller forced hidden for as long
/// as it's in the view hierarchy.
///
/// Reapplying only from SwiftUI's `updateNSView` — the prior mechanism — misses one trigger:
/// AppKit resets `NSScrollView.scrollerStyle` to the system's current preferred style whenever
/// `NSScroller.preferredScrollerStyleDidChangeNotification` fires (e.g. a mouse connects while
/// "Show scroll bars" is Automatic), independent of whether SwiftUI re-renders. With "Show scroll
/// bars" on Automatic and a mouse attached, that preferred style is `.legacy`, which reserves
/// gutter width regardless of whether a scroller is shown — so the gutter could come back on its
/// own, with no state change for SwiftUI to diff against. Observing that notification directly
/// closes the gap.
final class ScrollerHidingNSView: NSView {
    var onApply: (NSScrollView) -> Void = hideScroller
    private var styleObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            removeStyleObserver()
            return
        }
        reapply()
        guard styleObserver == nil else {
            return
        }
        styleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // AppKit's own response to this same notification could land synchronously within
            // `post()` itself, or be deferred onto the main queue alongside this handler —
            // NotificationCenter doesn't document which, or how it orders multiple observers of
            // one notification relative to each other. Reapplying directly here only beats an
            // uncooperative AppKit reset by accident, if ours happens to run after it. Deferring
            // to the next main-runloop turn instead — a `DispatchQueue.main.async` chained from
            // inside this handler only runs once this turn (and `post()`) has already finished —
            // guarantees we run after whatever this turn did, AppKit's reset included, regardless
            // of which order the two were invoked in.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.reapplyIfWindowed()
                }
            }
        }
    }

    func reapply() {
        guard let scrollView = enclosingScrollView else {
            return
        }
        onApply(scrollView)
    }

    private func reapplyIfWindowed() {
        guard window != nil else {
            return
        }
        reapply()
    }

    private func removeStyleObserver() {
        if let styleObserver {
            NotificationCenter.default.removeObserver(styleObserver)
        }
        styleObserver = nil
    }

    deinit {
        removeStyleObserver()
    }
}

/// Forces an `NSScrollView` to never draw or reserve space for a scroller,
/// regardless of the system's scroll-bar preference or input device.
///
/// Setting `hasVerticalScroller = false` alone stops the knob from drawing but
/// does not retroactively re-run the scroll view's internal layout pass, and
/// `.legacy` scroller style reserves gutter width independent of whether a
/// scroller is actually shown. `.overlay` style never reserves space, and an
/// explicit `tile()` forces the content view to pick up the new settings
/// immediately instead of on whatever layout pass happens next.
func hideScroller(on scrollView: NSScrollView) {
    scrollView.scrollerStyle = .overlay
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsetsZero
    scrollView.scrollerInsets = NSEdgeInsetsZero
    scrollView.tile()
}

/// The row's own rectangle, grown above and below by `outset`, plus `overhang`, for a row whose artwork reaches past
/// its layout frame. `overhang` is in the row's coordinates, origin at the row's top-left, for art that sticks out
/// sideways or only in places (the tracker's agent badge).
struct RowHitShape: Shape {
    let outset: CGFloat
    var overhang = Path()

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: 0, dy: -outset))
        path.addPath(overhang, transform: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return path
    }
}

struct ListRow<Content: View, LeadingDecoration: View, Background: View>: View {
    let selected: Bool
    let leadingInset: CGFloat
    /// How far the row's artwork reaches past its layout frame, above and below, and any art past it elsewhere
    /// (`RowHitShape`). Hover and taps cover it, so the visible edges are live while the layout spacing stays the frame's.
    let hitOutset: CGFloat
    let hitOverhang: Path
    var onTap: (() -> Void)?
    /// The pointer moved onto the row, for a list whose cursor hover moves (the focused tracker).
    var onHighlight: (() -> Void)?
    private let leadingDecoration: () -> LeadingDecoration
    private let background: (_ selected: Bool, _ pointerOver: Bool) -> Background
    private let content: () -> Content

    /// Whether the pointer is over the row: the tracker shows its cursor there even while it lacks focus.
    @State private var isPointerOver = false

    init(
        selected: Bool,
        leadingInset: CGFloat,
        hitOutset: CGFloat = 0,
        hitOverhang: Path = Path(),
        onTap: (() -> Void)? = nil,
        onHighlight: (() -> Void)? = nil,
        @ViewBuilder leadingDecoration: @escaping () -> LeadingDecoration,
        @ViewBuilder background: @escaping (_ selected: Bool, _ pointerOver: Bool) -> Background,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.selected = selected
        self.leadingInset = leadingInset
        self.hitOutset = hitOutset
        self.hitOverhang = hitOverhang
        self.onTap = onTap
        self.onHighlight = onHighlight
        self.leadingDecoration = leadingDecoration
        self.background = background
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if let onTap {
            rowContent
                .onTapGesture(perform: onTap)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        content()
            .padding(.leading, leadingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(selected, isPointerOver))
            .overlay(alignment: .leading) {
                leadingDecoration()
            }
            .contentShape(RowHitShape(outset: hitOutset, overhang: hitOverhang))
            .onHover { isPointerOver = $0 }
            .highlightOnHover {
                if !selected {
                    onHighlight?()
                }
            }
    }
}

extension ListRow where LeadingDecoration == EmptyView {
    init(
        selected: Bool,
        leadingInset: CGFloat = 0,
        onTap: (() -> Void)? = nil,
        onHighlight: (() -> Void)? = nil,
        @ViewBuilder background: @escaping (_ selected: Bool, _ pointerOver: Bool) -> Background,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            selected: selected,
            leadingInset: leadingInset,
            onTap: onTap,
            onHighlight: onHighlight,
            leadingDecoration: { EmptyView() },
            background: background,
            content: content
        )
    }
}
