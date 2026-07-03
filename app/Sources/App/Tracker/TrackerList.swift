import AppKit
import SwiftUI

struct TrackerList<Content: View>: View {
    let selectedID: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: selectedID) { _, nextID in
                guard let nextID else {
                    return
                }
                proxy.scrollTo(nextID, anchor: .center)
            }
        }
    }
}

struct TrackerListSectionHeader: View {
    let title: String
    let color: NSColor

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: Token.Radius.dot)
                .fill(color.swiftUI)
                .frame(width: 6, height: 6)

            Text(title)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(color.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)

            Rectangle()
                .fill(AppPalette.line.swiftUI)
                .frame(height: 1)
        }
        .padding(.leading, TrackerListMetrics.headerLeadingInset)
        .padding(.trailing, 12)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .frame(minHeight: 28, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TrackerListRow<Content: View, LeadingDecoration: View>: View {
    let selected: Bool
    let leadingInset: CGFloat
    var onTap: () -> Void
    @ViewBuilder var leadingDecoration: () -> LeadingDecoration
    @ViewBuilder var content: () -> Content

    @State private var isHovered = false

    var body: some View {
        content()
            .padding(.leading, leadingInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                leadingDecoration()
            }
            .onHover { isHovered = $0 }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Token.Radius.hairline)
            .fill(backgroundColor.swiftUI)
    }

    private var backgroundColor: NSColor {
        if selected {
            return AppPalette.selection
        }
        return isHovered ? AppPalette.hoverBackground : .clear
    }
}
