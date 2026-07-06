import SwiftUI

struct SegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    var showsSelectionBorder = false
    var title: (Option) -> String
    var onSelect: (Option) -> Void
    var helpText: (Option) -> String? = { _ in nil }
    var accessibilityLabel: (Option) -> String? = { _ in nil }
    var accessibilityValue: (Option) -> String? = { _ in nil }

    var body: some View {
        HStack(spacing: Token.Spacing.hairline) {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    Text(title(option))
                        .font(AppFonts.body.swiftUI)
                        .foregroundStyle((option == selection ? AppPalette.activeText : AppPalette.muted).swiftUI)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            RoundedRectangle(cornerRadius: Token.Radius.segment)
                                .fill((option == selection ? AppPalette.controlFill : .clear).swiftUI)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Token.Radius.segment)
                                        .strokeBorder(
                                            (showsSelectionBorder && option == selection ? AppPalette.activeControlBorder : .clear).swiftUI,
                                            lineWidth: 1
                                        )
                                )
                        )
                }
                .buttonStyle(.plain)
                .help(helpText(option) ?? "")
                .accessibilityLabel(accessibilityLabel(option) ?? "")
                .accessibilityValue(accessibilityValue(option) ?? "")
            }
        }
        .padding(Token.Spacing.tight)
        .frame(maxWidth: .infinity)
        .borderedCard(fill: AppPalette.panel)
    }
}
