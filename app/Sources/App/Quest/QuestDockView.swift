import AppKit
import MarkdownUI
import QuestmasterCore
import SwiftUI

struct QuestDockModel: Equatable {
    var sections: [QuestSection]
    var scope: QuestScope
    var selectedQuestID: String?
    var selectedQuestIDs: Set<String>
    var query: String
    var filterTokens: [ArtifactFilterToken]
    var filterSuggestions: [ArtifactFilterSuggestion]
    var selectedFilterSuggestionID: String?
    var filterSuggestionsVisible: Bool
    var filterFocusNonce: Int

    static let empty = QuestDockModel(
        sections: [],
        scope: .active,
        selectedQuestID: nil,
        selectedQuestIDs: [],
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
    var onSetScope: (QuestScope) -> Void
    var onSetQuery: (String) -> Void
    var onRemoveFilterToken: (ArtifactFilterToken) -> Void
    var onSelectFilterSuggestion: (ArtifactFilterSuggestion) -> Void
    var onFilterCommand: (UInt16) -> Bool
    var onFilterEndEditing: () -> Void
    var onSelectQuest: (String) -> Void
    var onToggleQuest: (String) -> Void
    var onDone: () -> Void
    var onDelete: () -> Void
    var onStart: () -> Void
    var onEdit: () -> Void

    @State private var filterFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopePicker
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

    private var scopePicker: some View {
        HStack(spacing: Token.Spacing.hairline) {
            ForEach(QuestScope.allCases, id: \.rawValue) { scope in
                Button {
                    onSetScope(scope)
                } label: {
                    Text(scope == .active ? "Active" : "Done")
                        .font(AppFonts.body.swiftUI)
                        .foregroundStyle((scope == model.scope ? AppPalette.activeText : AppPalette.muted).swiftUI)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            RoundedRectangle(cornerRadius: Token.Radius.segment)
                                .fill((scope == model.scope ? AppPalette.controlFill : .clear).swiftUI)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Token.Spacing.tight)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .fill(AppPalette.panel.swiftUI)
                .overlay(RoundedRectangle(cornerRadius: Token.Radius.card).strokeBorder(AppPalette.line.swiftUI, lineWidth: 1))
        )
        .padding(Token.Spacing.card)
    }

    private var filterField: some View {
        HStack(spacing: Token.Spacing.inline) {
            Text("/")
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
            ForEach(model.filterTokens) { token in
                ArtifactFilterTokenChip(
                    token: token,
                    onRemove: { onRemoveFilterToken(token) }
                )
            }
            ArtifactCommandTextField(
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
                    ArtifactFilterSuggestionList(
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
        TrackerList(selectedID: model.selectedQuestID) {
            ForEach(model.sections) { section in
                let color = sectionColor(section)
                TrackerListSectionHeader(title: section.title, color: color)
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
        VStack(alignment: .leading, spacing: 7) {
            Text(model.scope == .active ? "No active quests." : "No done quests.")
                .font(AppFonts.bodyBold.swiftUI)
                .foregroundStyle(AppPalette.bright.swiftUI)
            Text("Create a quest to keep lightweight project notes.")
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
            Spacer(minLength: 0)
        }
        .padding(Token.Spacing.content)
    }

}

private struct QuestRow: View {
    var quest: QuestItem
    var selected: Bool
    var checked: Bool
    var selectMode: Bool
    var onSelect: () -> Void
    var onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Token.Spacing.card) {
            if selectMode {
                Button(action: onToggle) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle((checked ? AppPalette.accent : AppPalette.muted).swiftUI)
                        .frame(width: 15, height: 15)
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
                        if quest.done {
                            StrikethroughStyle(.single)
                        }
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
            .background(cardBackground)
            .contentShape(RoundedRectangle(cornerRadius: Token.Radius.control))
            .onTapGesture(perform: onSelect)
            .onHover { isHovered = $0 }
        }
        .padding(.horizontal, Token.Spacing.card)
        .padding(.vertical, 2.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: selectMode)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Token.Radius.control)
            .fill(cardFill.swiftUI)
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(cardBorder.swiftUI, lineWidth: 1)
            )
    }

    private var cardFill: NSColor {
        selected ? AppPalette.selection : AppPalette.lineSoftSubtle
    }

    private var cardBorder: NSColor {
        if selected {
            return AppPalette.activeControlBorder
        }
        return isHovered ? AppPalette.hoverBorder : AppPalette.lineSoftSubtle
    }

    private var markdownTextColor: Color {
        if quest.done {
            return AppPalette.dim.swiftUI
        }
        return (selected ? AppPalette.bright : AppPalette.text).swiftUI
    }

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
