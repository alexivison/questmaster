import AppKit
import SwiftUI

struct ModalSheetScaffold<Content: View>: View {
    let title: String
    let errorMessage: String?
    var horizontalInset = PanelMetrics.contentInset
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
        FlankedRule {
            HStack(spacing: Space.item) {
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
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, Space.item)
        .padding(.bottom, Space.section)
    }
}

/// Every modal's header (`PanelHeaderMetrics`): the shared `PanelTitle`, `elementGap` above the chapter rule's band, and the
/// panel's content `contentGap` under the band. The title sits where a dock's does.
struct ModalSheetHeader: View {
    /// The title's text frame, the gap, and the rule's band: where the header's own elements end.
    static let height = PanelHeaderMetrics.titleRowHeight + PanelHeaderMetrics.elementGap + ModalChapterRuleMetrics.band

    let title: String
    var titleColor: NSColor = AppPalette.accent
    var horizontalInset = PanelMetrics.contentInset

    var body: some View {
        VStack(spacing: PanelHeaderMetrics.elementGap) {
            PanelTitle(text: title, color: titleColor)
                .frame(height: PanelHeaderMetrics.titleRowHeight)
            ModalChapterRule()
        }
        .padding(.horizontal, horizontalInset)
        .frame(height: Self.height)
        .padding(.bottom, PanelHeaderMetrics.contentGap)
    }
}
