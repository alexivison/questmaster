import AppKit
import SwiftUI

struct SectionedList<Content: View>: View {
    let selectedID: String?
    var scrollOnAppear = false
    var scrollOnSelectionChange = true
    var scrollTargetID: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
}

struct SectionHeader: View {
    let title: String
    let color: NSColor
    var leadingInset: CGFloat = Token.Spacing.content

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color.swiftUI)
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(45))

            Text(title)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(color.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)

            Rectangle()
                .fill(AppPalette.line.swiftUI)
                .frame(height: 1)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .frame(minHeight: 28, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
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
