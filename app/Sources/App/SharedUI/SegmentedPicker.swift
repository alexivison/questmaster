import SwiftUI

struct SegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
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
                    VStack(spacing: Token.Spacing.inline) {
                        Text(title(option))
                            .font(AppFonts.dockTabTitle.swiftUI)
                            .textCase(.uppercase)
                            .tracking(1.6)
                            .foregroundStyle((option == selection ? AppPalette.accent : AppPalette.dim).swiftUI)
                            .lineLimit(1)
                        FlankedOrnamentRule(
                            color: (option == selection ? AppPalette.brassActive : AppPalette.line).swiftUI,
                            centerSpacing: 0
                        ) {
                            Color.clear.frame(width: 0, height: 0)
                        }
                        .frame(height: 11)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .optionalHelp(helpText(option))
                .optionalAccessibilityLabel(accessibilityLabel(option))
                .optionalAccessibilityValue(accessibilityValue(option))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private extension View {
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }

    @ViewBuilder
    func optionalAccessibilityLabel(_ text: String?) -> some View {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            accessibilityLabel(text)
        } else {
            self
        }
    }

    @ViewBuilder
    func optionalAccessibilityValue(_ text: String?) -> some View {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            accessibilityValue(text)
        } else {
            self
        }
    }
}
