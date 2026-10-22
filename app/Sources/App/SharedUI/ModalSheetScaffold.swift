import AppKit
import SwiftUI

struct ModalSheetScaffold<Content: View>: View {
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
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ModalSheetHeader(title: title, titleColor: titleColor, horizontalInset: horizontalInset)
            content()
            errorRow
            if hasFooter {
                footer
            }
        }
    }

    /// A sheet with no buttons and no hint (Settings) ends without the footer's rule.
    private var hasFooter: Bool {
        (cancelLabel != nil && onCancel != nil) || (primaryLabel != nil && onPrimary != nil) || !footerText.isEmpty
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

    private var footer: some View {
        VStack(spacing: footerText.isEmpty ? 0 : Token.Spacing.section) {
            FlankedOrnamentRule(style: .simple, centerSpacing: Token.Spacing.element) {
                HStack(spacing: Token.Spacing.element) {
                    if let cancelLabel, let onCancel {
                        Button(cancelLabel, action: onCancel)
                            .buttonStyle(OutlineButtonStyle())
                    }
                    if let primaryLabel, let onPrimary {
                        if destructivePrimary {
                            Button(primaryLabel, action: onPrimary)
                                .buttonStyle(DangerButtonStyle())
                                .keyboardShortcut(.defaultAction)
                        } else {
                            Button(primaryLabel, action: onPrimary)
                                .buttonStyle(GoldButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, ModalSheetMetrics.footerRuleInset)

            Text(footerText)
                .font(AppFonts.monoSmall.withSize(10.5).swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: footerText.isEmpty ? 0 : ModalSheetMetrics.footerHintHeight)
                .clipped()
        }
        .padding(.top, Token.Spacing.element)
        .padding(.bottom, ModalSheetMetrics.footerBottomInset)
    }
}

/// Every modal's title, as written, over the chapter rule. Measured from user-quests-modal-v3.svg: the title's
/// baseline 39 down, the rule's 18pt band at y 54-72, and the content 8 below it.
struct ModalSheetHeader: View {
    let title: String
    var titleColor: NSColor = AppPalette.accent
    var horizontalInset: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(AppFonts.title.swiftUI)
                .foregroundStyle(titleColor.swiftUI)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 21)
                .padding(.bottom, 10)
                .padding(.horizontal, horizontalInset)

            ModalChapterRule()
                .padding(.horizontal, horizontalInset)
                .padding(.bottom, 8)
        }
    }
}

private enum ModalSheetMetrics {
    static let footerRuleInset: CGFloat = 30
    static let footerHintHeight: CGFloat = 13
    static let footerBottomInset: CGFloat = 20
}
