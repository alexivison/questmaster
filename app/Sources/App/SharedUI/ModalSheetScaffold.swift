import AppKit
import SwiftUI

struct ModalSheetScaffold<Content: View, Trailing: View>: View {
    let title: String
    let footerText: String
    let errorMessage: String?
    var horizontalInset: CGFloat = 18
    var errorHeight: CGFloat = 46
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(AppPalette.bright.swiftUI)
                Spacer(minLength: 12)
                trailing()
            }
            .frame(height: 58)
            .padding(.horizontal, horizontalInset)

            divider
            content()
            errorRow
            divider

            Text(footerText)
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 42)
                .padding(.horizontal, horizontalInset)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(AppPalette.line.swiftUI)
            .frame(height: 1)
    }

    private var errorRow: some View {
        let error = errorMessage ?? ""
        return Text(error)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.deleted.swiftUI)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 6)
            .frame(height: error.isEmpty ? 0 : errorHeight, alignment: .topLeading)
            .clipped()
    }
}

extension ModalSheetScaffold where Trailing == EmptyView {
    init(
        title: String,
        footerText: String,
        errorMessage: String?,
        horizontalInset: CGFloat = 18,
        errorHeight: CGFloat = 46,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            footerText: footerText,
            errorMessage: errorMessage,
            horizontalInset: horizontalInset,
            errorHeight: errorHeight,
            trailing: { EmptyView() },
            content: content
        )
    }
}

struct ModalSelectRow: View {
    let label: String
    let labelWidth: CGFloat
    let title: String
    let note: String
    let swatchColor: NSColor?
    let focused: Bool
    let disabled: Bool
    let controlWidth: CGFloat
    var horizontalInset: CGFloat = 18
    var spacing: CGFloat = 18
    var onSelect: () -> Void

    var body: some View {
        ModalFormRow(
            label: label,
            labelWidth: labelWidth,
            horizontalInset: horizontalInset,
            spacing: spacing
        ) {
            HStack(spacing: 12) {
                ModalSelectControl(
                    title: title,
                    swatchColor: swatchColor,
                    focused: focused,
                    disabled: disabled
                )
                .frame(width: controlWidth, height: 36)
                .onTapGesture(perform: onSelect)

                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
