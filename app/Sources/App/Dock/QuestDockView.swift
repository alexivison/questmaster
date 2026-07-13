import AppKit
import MarkdownUI
import QuestmasterCore
import SwiftUI

struct QuestDockModel: Equatable {
    var sections: [QuestSection]
    var selectedQuestID: String?
    var selectedQuestIDs: Set<String>
    var scrollTargetID: String?
    var query: String
    var filterTokens: [ArtifactFilterToken]
    var filterSuggestions: [ArtifactFilterSuggestion]
    var selectedFilterSuggestionID: String?
    var filterSuggestionsVisible: Bool
    var filterFocusNonce: Int

    static let empty = QuestDockModel(
        sections: [],
        selectedQuestID: nil,
        selectedQuestIDs: [],
        scrollTargetID: nil,
        query: "",
        filterTokens: [],
        filterSuggestions: [],
        selectedFilterSuggestionID: nil,
        filterSuggestionsVisible: false,
        filterFocusNonce: 0
    )
}

struct QuestDockView: View {
    var model: QuestDockModel
    var onSetQuery: (String) -> Void
    var onRemoveFilterToken: (ArtifactFilterToken) -> Void
    var onSelectFilterSuggestion: (ArtifactFilterSuggestion) -> Void
    var onFilterCommand: (UInt16) -> Bool
    var onFilterEndEditing: () -> Void
    var onSelectQuest: (String) -> Void
    var onToggleQuest: (String) -> Void
    var onDelete: () -> Void
    var onStart: () -> Void
    var onEdit: () -> Void

    @State private var filterFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterControls
            if model.sections.isEmpty {
                emptyState
            } else {
                questList
            }
        }
        .background(AppPalette.artifactListColumn.swiftUI)
        .onChange(of: model.filterFocusNonce) { _, _ in
            filterFocused = true
        }
    }

    private var filterField: some View {
        HStack(spacing: Token.Spacing.inline) {
            Text("/")
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
            ForEach(model.filterTokens) { token in
                FilterTokenChip(
                    token: token,
                    onRemove: { onRemoveFilterToken(token) }
                )
            }
            CommandTextField(
                text: Binding(get: { model.query }, set: onSetQuery),
                placeholder: "@project: or text",
                focusNonce: model.filterFocusNonce,
                onCommand: onFilterCommand,
                onEndEditing: onFilterEndEditing,
                onFocusChanged: { filterFocused = $0 }
            )
            .frame(minWidth: 80, maxWidth: .infinity, minHeight: 22)
        }
        .padding(.horizontal, Token.Spacing.card)
        .padding(.vertical, 4)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .fill(AppPalette.panel.swiftUI)
                .overlay(RoundedRectangle(cornerRadius: Token.Radius.control).strokeBorder((filterFocused ? AppPalette.accent : AppPalette.line).swiftUI, lineWidth: 1))
        )
        .accessibilityLabel("Filter quests")
    }

    private var filterControls: some View {
        filterField
            .overlay(alignment: .topLeading) {
                if filterFocused && model.filterSuggestionsVisible {
                    FilterSuggestionList(
                        suggestions: model.filterSuggestions,
                        selectedID: model.selectedFilterSuggestionID,
                        onSelect: onSelectFilterSuggestion
                    )
                    .offset(y: 38)
                    .zIndex(3)
                }
            }
            .padding(.horizontal, Token.Spacing.card)
            .padding(.bottom, Token.Spacing.card)
            .zIndex(2)
    }

    private var questList: some View {
        SectionedList(
            selectedID: model.selectedQuestID,
            scrollOnSelectionChange: false,
            scrollTargetID: model.scrollTargetID
        ) {
            ForEach(model.sections) { section in
                let color = sectionColor(section)
                SectionHeader(title: section.title, color: color)
                ForEach(section.quests) { quest in
                    QuestRow(
                        quest: quest,
                        selected: quest.id == model.selectedQuestID,
                        checked: model.selectedQuestIDs.contains(quest.id),
                        selectMode: !model.selectedQuestIDs.isEmpty,
                        onSelect: { onSelectQuest(quest.id) },
                        onToggle: { onToggleQuest(quest.id) }
                    )
                    .id(quest.id)
                }
            }
        }
    }

    private func sectionColor(_ section: QuestSection) -> NSColor {
        AppPalette.displayColorName(section.color) ?? AppPalette.muted
    }

    private var emptyState: some View {
        EmptyStatePane(
            title: "No quests.",
            message: "Create a quest to keep lightweight project notes.",
            padding: EdgeInsets(
                top: Token.Spacing.content,
                leading: Token.Spacing.content,
                bottom: Token.Spacing.content,
                trailing: Token.Spacing.content
            )
        )
    }

}

private struct QuestRow: View {
    var quest: QuestItem
    var selected: Bool
    var checked: Bool
    var selectMode: Bool
    var onSelect: () -> Void
    var onToggle: () -> Void

    var body: some View {
        ListRow(selected: selected) { selected, hovered in
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .fill(cardFill(selected).swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.control)
                        .strokeBorder(cardBorder(selected: selected, hovered: hovered).swiftUI, lineWidth: 1)
                )
                .padding(.leading, cardLeadingInset)
                .padding(.trailing, Token.Spacing.card)
                .padding(.vertical, 2.5)
        } content: {
            HStack(alignment: .top, spacing: Token.Spacing.card) {
                if selectMode {
                    Button(action: onToggle) {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle((checked ? AppPalette.accent : AppPalette.muted).swiftUI)
                            .frame(width: checkboxWidth, height: checkboxWidth)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 9)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                VStack(alignment: .leading, spacing: 0) {
                    Markdown(quest.content)
                        .markdownTheme(.basic)
                        .markdownTextStyle {
                            FontSize(13)
                            ForegroundColor(markdownTextColor)
                        }
                        .markdownTextStyle(\.code) {
                            FontFamilyVariant(.monospaced)
                            FontSize(11.5)
                            ForegroundColor(AppPalette.added.swiftUI)
                            BackgroundColor(AppPalette.window.swiftUI)
                        }
                        .markdownBlockStyle(\.heading1) { Self.compactHeading($0) }
                        .markdownBlockStyle(\.heading2) { Self.compactHeading($0) }
                        .markdownBlockStyle(\.heading3) { Self.compactHeading($0) }
                        .markdownBlockStyle(\.heading4) { Self.compactHeading($0) }
                        .markdownBlockStyle(\.heading5) { Self.compactHeading($0) }
                        .markdownBlockStyle(\.heading6) { Self.compactHeading($0) }
                        .markdownBlockStyle(\.paragraph) { configuration in
                            configuration.label
                                .fixedSize(horizontal: false, vertical: true)
                                .relativeLineSpacing(.em(0.15))
                                .markdownMargin(top: 0, bottom: 3)
                        }
                        .markdownBlockStyle(\.list) { configuration in
                            configuration.label.markdownMargin(top: 2, bottom: 3)
                        }
                        .markdownBlockStyle(\.listItem) { configuration in
                            configuration.label.markdownMargin(top: 1)
                        }
                        .markdownImageProvider(LocalMarkdownImageProvider())
                        .markdownInlineImageProvider(LocalMarkdownInlineImageProvider())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !metadataText.isEmpty {
                        Text(metadataText)
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.dim.swiftUI)
                            .lineLimit(1)
                            .padding(.top, Token.Spacing.inline)
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: Token.Radius.control))
                .onTapGesture(perform: onSelect)
            }
            .padding(.horizontal, Token.Spacing.card)
            .padding(.vertical, 2.5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeInOut(duration: 0.16), value: selectMode)
    }

    private var cardLeadingInset: CGFloat {
        Token.Spacing.card + (selectMode ? checkboxWidth + Token.Spacing.card : 0)
    }

    private var checkboxWidth: CGFloat { 15 }

    private func cardFill(_ selected: Bool) -> NSColor {
        selected ? AppPalette.selection : AppPalette.lineSoftSubtle
    }

    private func cardBorder(selected: Bool, hovered: Bool) -> NSColor {
        if selected {
            return AppPalette.activeControlBorder
        }
        return hovered ? AppPalette.hoverBorder : AppPalette.lineSoftSubtle
    }

    private var markdownTextColor: Color { (selected ? AppPalette.bright : AppPalette.text).swiftUI }

    private var metadataText: String {
        let raw = quest.updatedAt.isEmpty ? quest.createdAt : quest.updatedAt
        guard !raw.isEmpty else {
            return ""
        }
        let normalized = raw.replacingOccurrences(of: "T", with: " ")
        return String(normalized.prefix(16))
    }

    private static func compactHeading(_ configuration: BlockConfiguration) -> some View {
        configuration.label
            .markdownTextStyle {
                FontWeight(.semibold)
                FontSize(13)
                ForegroundColor(AppPalette.bright.swiftUI)
            }
            .markdownMargin(top: 0, bottom: 3)
    }
}
