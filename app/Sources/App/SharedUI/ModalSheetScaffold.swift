import AppKit
import SwiftUI

struct ModalSheetScaffold<Content: View, Trailing: View>: View {
    let title: String
    let footerText: String
    let errorMessage: String?
    var horizontalInset: CGFloat = 18
    var errorHeight: CGFloat = 46
    /// The one departure from the shared gold chrome: a destructive sheet's
    /// title stays semantic red so its danger signal survives the theme.
    var titleColor: NSColor = AppPalette.accent
    var cancelLabel: String?
    var onCancel: (() -> Void)?
    var primaryLabel: String?
    var onPrimary: (() -> Void)?
    var destructivePrimary = false
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(AppFonts.title.swiftUI)
                    .textCase(.uppercase)
                    .tracking(1.4)
                    .foregroundStyle(titleColor.swiftUI)
                Spacer(minLength: 12)
                trailing()
            }
            .frame(height: 58)
            .padding(.horizontal, horizontalInset)

            ModalChapterRule()
                .padding(.horizontal, horizontalInset)
                .padding(.bottom, 8)
            content()
            errorRow
            divider

            HStack(spacing: 10) {
                Text(footerText)
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let cancelLabel, let onCancel {
                    Button(cancelLabel, action: onCancel)
                        .buttonStyle(OutlineButtonStyle())
                }
                if let primaryLabel, let onPrimary {
                    if destructivePrimary {
                        Button(primaryLabel, action: onPrimary)
                            .buttonStyle(DangerButtonStyle())
                    } else {
                        Button(primaryLabel, action: onPrimary)
                            .buttonStyle(GoldButtonStyle())
                    }
                }
            }
            .frame(height: 56)
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
        titleColor: NSColor = AppPalette.accent,
        cancelLabel: String? = nil,
        onCancel: (() -> Void)? = nil,
        primaryLabel: String? = nil,
        onPrimary: (() -> Void)? = nil,
        destructivePrimary: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            footerText: footerText,
            errorMessage: errorMessage,
            horizontalInset: horizontalInset,
            errorHeight: errorHeight,
            titleColor: titleColor,
            cancelLabel: cancelLabel,
            onCancel: onCancel,
            primaryLabel: primaryLabel,
            onPrimary: onPrimary,
            destructivePrimary: destructivePrimary,
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
                    .font(AppFonts.modalHelper.swiftUI)
                    .italic()
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
