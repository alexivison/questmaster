import AppKit
import QuestmasterCore
import SwiftUI

struct SectionedList<Content: View>: View {
    let selectedID: String?
    var scrollOnAppear = false
    var scrollOnSelectionChange = true
    var scrollTargetID: String?
    private let content: () -> Content
    @State private var scrollDebounceTask: Task<Void, Never>?

    init(
        selectedID: String?,
        scrollOnAppear: Bool = false,
        scrollOnSelectionChange: Bool = true,
        scrollTargetID: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.selectedID = selectedID
        self.scrollOnAppear = scrollOnAppear
        self.scrollOnSelectionChange = scrollOnSelectionChange
        self.scrollTargetID = scrollTargetID
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SectionedListScrollerHider())
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
                scheduleScroll(with: proxy, id: nextID)
            }
            .onChange(of: scrollTargetID) { _, nextID in
                scheduleScroll(with: proxy, id: nextID)
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

private struct SectionedListScrollerHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = nsView.enclosingScrollView else {
                return
            }
            hideScroller(on: scrollView)
        }
    }
}

/// Forces an `NSScrollView` to never draw or reserve space for a scroller,
/// regardless of the system's scroll-bar preference or input device.
///
/// Setting `hasVerticalScroller = false` alone stops the knob from drawing but
/// does not retroactively re-run the scroll view's internal layout pass, and
/// `.legacy` scroller style reserves gutter width independent of whether a
/// scroller is actually shown. `.overlay` style never reserves space, and an
/// explicit `tile()` (AppKit's private but widely-relied-on relayout trigger
/// for exactly this scenario) forces the content view to pick up the new
/// settings immediately instead of on whatever layout pass happens next.
func hideScroller(on scrollView: NSScrollView) {
    scrollView.scrollerStyle = .overlay
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsetsZero
    scrollView.scrollerInsets = NSEdgeInsetsZero
    scrollView.perform(NSSelectorFromString("tile"))
}

struct SectionHeader: View {
    let title: String
    let color: NSColor
    var leadingInset: CGFloat = Token.Spacing.content
    var topInset: CGFloat = 12
    var bottomInset: CGFloat = 5

    var body: some View {
        FlankedOrnamentRule(color: AppPalette.controlBorder.swiftUI) {
            Text(title)
                .font(AppFonts.sectionTitle.swiftUI)
                .foregroundStyle(color.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .offset(y: -3)
        }
        .padding(.horizontal, leadingInset)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(minHeight: 28, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ListRow<Content: View, LeadingDecoration: View, Background: View>: View {
    let selected: Bool
    let leadingInset: CGFloat
    var onTap: (() -> Void)?
    private let leadingDecoration: () -> LeadingDecoration
    private let background: (_ selected: Bool, _ hovered: Bool) -> Background
    private let content: () -> Content

    @State private var isHovered = false

    init(
        selected: Bool,
        leadingInset: CGFloat,
        onTap: (() -> Void)? = nil,
        @ViewBuilder leadingDecoration: @escaping () -> LeadingDecoration,
        @ViewBuilder background: @escaping (_ selected: Bool, _ hovered: Bool) -> Background,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.selected = selected
        self.leadingInset = leadingInset
        self.onTap = onTap
        self.leadingDecoration = leadingDecoration
        self.background = background
        self.content = content
    }

    @ViewBuilder
    var body: some View {
        if let onTap {
            rowContent
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        content()
            .padding(.leading, leadingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(selected, isHovered))
            .overlay(alignment: .leading) {
                leadingDecoration()
            }
            .onHover { isHovered = $0 }
    }
}

extension ListRow where LeadingDecoration == EmptyView {
    init(
        selected: Bool,
        leadingInset: CGFloat = 0,
        onTap: (() -> Void)? = nil,
        @ViewBuilder background: @escaping (_ selected: Bool, _ hovered: Bool) -> Background,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            selected: selected,
            leadingInset: leadingInset,
            onTap: onTap,
            leadingDecoration: { EmptyView() },
            background: background,
            content: content
        )
    }
}
