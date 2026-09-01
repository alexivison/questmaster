import AppKit
import QuestmasterCore
import SwiftUI

private struct SectionedListContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SectionedListViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct SectionedList<Content: View, Footer: View>: View {
    let selectedID: String?
    var scrollOnAppear = false
    var scrollOnSelectionChange = true
    var scrollTargetID: String?
    let footerHeight: CGFloat
    private let content: () -> Content
    private let footer: () -> Footer
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    init(
        selectedID: String?,
        scrollOnAppear: Bool = false,
        scrollOnSelectionChange: Bool = true,
        scrollTargetID: String? = nil,
        footerHeight: CGFloat,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.selectedID = selectedID
        self.scrollOnAppear = scrollOnAppear
        self.scrollOnSelectionChange = scrollOnSelectionChange
        self.scrollTargetID = scrollTargetID
        self.footerHeight = footerHeight
        self.content = content
        self.footer = footer
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SectionedListContentHeightKey.self, value: proxy.size.height)
                    }
                }
                .background(SectionedListScrollerHider())
                if showsFooter {
                    footer()
                }
            }
            .scrollIndicators(.hidden)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: SectionedListViewportHeightKey.self, value: proxy.size.height)
                }
            }
            .onPreferenceChange(SectionedListContentHeightKey.self) { contentHeight = $0 }
            .onPreferenceChange(SectionedListViewportHeightKey.self) { viewportHeight = $0 }
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
                scrollSelected(with: proxy, id: nextID)
            }
            .onChange(of: scrollTargetID) { _, nextID in
                scrollSelected(with: proxy, id: nextID)
            }
        }
    }

    private func scrollSelected(with proxy: ScrollViewProxy, id: String?) {
        guard let id else {
            return
        }
        proxy.scrollTo(id, anchor: .center)
    }

    private var showsFooter: Bool {
        guard footerHeight > 0 else {
            return false
        }
        return TrackerEndOrnamentVisibility.shows(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            ornamentHeight: footerHeight
        )
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
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
        }
    }
}

extension SectionedList where Footer == EmptyView {
    init(
        selectedID: String?,
        scrollOnAppear: Bool = false,
        scrollOnSelectionChange: Bool = true,
        scrollTargetID: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            selectedID: selectedID,
            scrollOnAppear: scrollOnAppear,
            scrollOnSelectionChange: scrollOnSelectionChange,
            scrollTargetID: scrollTargetID,
            footerHeight: 0,
            content: content,
            footer: { EmptyView() }
        )
    }
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
