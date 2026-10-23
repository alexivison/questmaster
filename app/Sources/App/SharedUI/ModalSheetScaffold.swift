import AppKit
import SwiftUI

struct ModalSheetScaffold<Content: View>: View {
    let title: String
    let errorMessage: String?
    var horizontalInset = Space.section
    var errorHeight: CGFloat = 45
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

    /// A sheet with no buttons (Settings) ends without the footer's rule.
    private var hasFooter: Bool {
        (cancelLabel != nil && onCancel != nil) || (primaryLabel != nil && onPrimary != nil)
    }

    private var errorRow: some View {
        let error = errorMessage ?? ""
        return Text(error)
            .font(AppFonts.monoSmall.swiftUI)
            .foregroundStyle(AppPalette.deleted.swiftUI)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, Space.row)
            .frame(height: error.isEmpty ? 0 : errorHeight, alignment: .topLeading)
            .clipped()
    }

    private var footer: some View {
        FlankedOrnamentRule(style: .simple) {
            HStack(spacing: Space.item) {
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
        .padding(.horizontal, horizontalInset)
        .padding(.top, Space.item)
        .padding(.bottom, Space.section)
    }
}

/// Every modal's title over the chapter rule, from user-quests-modal-v3.svg: the title's baseline 39 down and the
/// rule's 18pt band ending 70 down, so the content starts `Space.item` under it, 80 down.
struct ModalSheetHeader: View {
    static let height: CGFloat = 70
    static let titleBaseline: CGFloat = 39

    let title: String
    var titleColor: NSColor = AppPalette.accent
    var horizontalInset = Space.section

    var body: some View {
        VStack(spacing: 0) {
            BaselineText(title, font: AppFonts.title, color: titleColor, baseline: Self.titleBaseline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, horizontalInset)
            ModalChapterRule()
                .padding(.horizontal, horizontalInset)
        }
        .frame(height: Self.height)
        .padding(.bottom, Space.item)
    }
}
