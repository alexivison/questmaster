import AppKit
import QuestmasterCore
import SwiftUI

struct ArtifactFilterOption: Equatable, Identifiable {
    var id: String
    var title: String
}

struct ArtifactDockModel: Equatable {
    var currentSessionTitle: String
    var currentSessionID: String
    var artifacts: [ArtifactReference]
    var projectTitlesByArtifactID: [String: String] = [:]
    var artifactScope: ArtifactScope
    var selectedArtifactID: String?
    var route: ArtifactDockRoute
    var displayState: ArtifactViewerDisplayState
    var artifactFilterQuery: String = ""
    var artifactFilterTokens: [ArtifactFilterToken] = []
    var filterSuggestions: [ArtifactFilterSuggestion] = []
    var selectedFilterSuggestionID: String?
    var filterSuggestionsVisible: Bool = false
    var artifactProjectFilterIDs: Set<String> = []
    var artifactTypeFilterIDs: Set<String> = []
    var projectFilterOptions: [ArtifactFilterOption] = []
    var typeFilterOptions: [ArtifactFilterOption] = []
    var filterFocusNonce: Int = 0
    /// Bumped to force the viewer to reload the current artifact on demand.
    var reloadNonce: Int = 0

    static let empty = ArtifactDockModel(
        currentSessionTitle: "",
        currentSessionID: "",
        artifacts: [],
        artifactScope: .session,
        selectedArtifactID: nil,
        route: .list,
        displayState: .noCurrentSession
    )
}

struct ArtifactDockView: View {
    var model: ArtifactDockModel
    var onSelectArtifact: (String) -> Void
    var onSetScope: (ArtifactScope) -> Void
    var onSetFilterQuery: (String) -> Void
    var onRemoveFilterToken: (ArtifactFilterToken) -> Void
    var onSelectFilterSuggestion: (ArtifactFilterSuggestion) -> Void
    var onFilterCommand: (UInt16) -> Bool
    var onFilterEndEditing: () -> Void
    var onOpenExternal: (URL) -> Void

    @State private var filterFocused = false

    var body: some View {
        switch model.route {
        case .list:
            artifactSelector
        case .viewer:
            ArtifactViewerPane(
                displayState: model.displayState,
                reloadNonce: model.reloadNonce,
                onOpenExternal: onOpenExternal
            )
        }
    }

    private var artifactSelector: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopePicker
            if model.artifactScope == .all {
                filterControls
            }
            switch model.displayState {
            case .noCurrentSession:
                selectorStatus("No current session.", detail: "Select a running session in the tracker.")
            case .empty:
                selectorStatus(emptyTitle, detail: emptyDetail)
            case .missing, .unsupported, .viewing:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.artifacts) { artifact in
                                ArtifactRow(
                                    artifact: artifact,
                                    projectTitle: projectTitle(for: artifact),
                                    selected: artifact.id == model.selectedArtifactID,
                                    action: { onSelectArtifact(artifact.id) }
                                )
                                .id(artifact.id)
                            }
                        }
                        .padding(Token.Spacing.card)
                    }
                    .accessibilityLabel("Artifact list")
                    .onAppear {
                        scrollSelectedArtifact(with: proxy)
                    }
                    .onChange(of: model.selectedArtifactID) { _, _ in
                        scrollSelectedArtifact(with: proxy)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppPalette.artifactListColumn.swiftUI)
    }

    private var filterBinding: Binding<String> {
        Binding(
            get: { model.artifactFilterQuery },
            set: onSetFilterQuery
        )
    }

    private var filterControls: some View {
        filterField
        .overlay(alignment: .topLeading) {
            if filterFocused && model.filterSuggestionsVisible {
                filterSuggestionList
                    .offset(y: 38)
                    .zIndex(3)
            }
        }
        .padding(.horizontal, Token.Spacing.card)
        .padding(.bottom, Token.Spacing.card)
        .zIndex(2)
    }

    private var filterField: some View {
        HStack(spacing: Token.Spacing.inline) {
            Text("/")
                .font(AppFonts.monoSmall.swiftUI)
                .foregroundStyle(AppPalette.dim.swiftUI)
            ForEach(model.artifactFilterTokens) { token in
                ArtifactFilterTokenChip(
                    token: token,
                    onRemove: { onRemoveFilterToken(token) }
                )
            }
            ArtifactCommandTextField(
                text: filterBinding,
                placeholder: "@project: @type: or text",
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
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.control)
                        .strokeBorder((filterFocused ? AppPalette.accent : AppPalette.line).swiftUI, lineWidth: 1)
                )
        )
        .accessibilityLabel("Filter artifacts")
    }

    private var filterSuggestionList: some View {
        VStack(spacing: Token.Spacing.hairline) {
            ForEach(model.filterSuggestions) { suggestion in
                Button {
                    onSelectFilterSuggestion(suggestion)
                } label: {
                    HStack(spacing: Token.Spacing.inline) {
                        Text(suggestion.title)
                            .font(AppFonts.body.swiftUI)
                            .foregroundStyle(AppPalette.text.swiftUI)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(suggestion.detail)
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.dim.swiftUI)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, Token.Spacing.card)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Token.Radius.control)
                            .fill((suggestion.id == model.selectedFilterSuggestionID ? AppPalette.hoverBackground : .clear).swiftUI)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .fill(AppPalette.controlFill.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.card)
                        .strokeBorder(AppPalette.hoverBorder.swiftUI, lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 18, y: 10)
        .accessibilityLabel("Filter suggestions")
    }

    private var emptyTitle: String {
        hasActiveFilter ? "No matching artifacts." : model.artifactScope.emptyTitle
    }

    private var emptyDetail: String {
        hasActiveFilter ? "Clear the filter to show all artifacts." : model.artifactScope.emptyDetail
    }

    private var hasActiveFilter: Bool {
        model.artifactScope == .all && (
            !model.artifactFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !model.artifactProjectFilterIDs.isEmpty
            || !model.artifactTypeFilterIDs.isEmpty
        )
    }

    private func scrollSelectedArtifact(with proxy: ScrollViewProxy) {
        guard let selectedArtifactID = model.selectedArtifactID,
              model.artifacts.contains(where: { $0.id == selectedArtifactID }) else {
            return
        }
        proxy.scrollTo(selectedArtifactID, anchor: .center)
    }

    private func projectTitle(for artifact: ArtifactReference) -> String {
        model.projectTitlesByArtifactID[artifact.id] ?? "Unknown Project"
    }

    private var scopePicker: some View {
        HStack(spacing: Token.Spacing.hairline) {
            ForEach(ArtifactScope.dockCases, id: \.rawValue) { scope in
                Button {
                    onSetScope(scope)
                } label: {
                    Text(scope.title)
                        .font(AppFonts.body.swiftUI)
                        .foregroundStyle((scope == model.artifactScope ? AppPalette.activeText : AppPalette.muted).swiftUI)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            RoundedRectangle(cornerRadius: Token.Radius.segment)
                                .fill((scope == model.artifactScope ? AppPalette.controlFill : .clear).swiftUI)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Token.Radius.segment)
                                        .strokeBorder((scope == model.artifactScope ? AppPalette.activeControlBorder : .clear).swiftUI, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
                .help("Show \(scope.title.lowercased()) artifacts")
                .accessibilityLabel("Artifact scope \(scope.title)")
                .accessibilityValue(scope == model.artifactScope ? "Selected" : "")
            }
        }
        .padding(Token.Spacing.tight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .fill(AppPalette.panel.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.card)
                        .strokeBorder(AppPalette.line.swiftUI, lineWidth: 1)
                )
        )
        .padding(Token.Spacing.card)
    }

    private func selectorStatus(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(AppFonts.bodyBold.swiftUI)
                .foregroundStyle(AppPalette.bright.swiftUI)
            Text(detail)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Token.Spacing.content)
    }
}

private struct ArtifactFilterTokenChip: View {
    var token: ArtifactFilterToken
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(token.kind.prefix)
                .font(AppFonts.bodyBold.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
            Text(token.title)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.text.swiftUI)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppPalette.muted.swiftUI)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Remove \(token.kind.rawValue) filter")
            .accessibilityLabel("Remove \(token.kind.rawValue) filter \(token.title)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .fill(AppPalette.controlFill.swiftUI)
                .overlay(
                    RoundedRectangle(cornerRadius: Token.Radius.control)
                        .strokeBorder(AppPalette.line.swiftUI, lineWidth: 1)
                )
        )
    }
}

private struct ArtifactCommandTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusNonce: Int
    var onCommand: (UInt16) -> Bool
    var onEndEditing: () -> Void
    var onFocusChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onCommand: onCommand,
            onEndEditing: onEndEditing,
            onFocusChanged: onFocusChanged
        )
    }

    func makeNSView(context: Context) -> KeyTextField {
        let field = KeyTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFonts.body
        field.textColor = AppPalette.text
        field.cell?.usesSingleLineMode = true
        field.onCommand = onCommand
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: KeyTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommand = onCommand
        context.coordinator.onEndEditing = onEndEditing
        context.coordinator.onFocusChanged = onFocusChanged
        field.onCommand = onCommand
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: AppPalette.dim,
                .font: AppFonts.body,
            ]
        )
        field.setEditorText(text)
        guard context.coordinator.consumeFocusNonce(focusNonce) else {
            return
        }
        DispatchQueue.main.async {
            field.focusEditorAtEnd()
            onFocusChanged(field.currentEditor() != nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommand: (UInt16) -> Bool
        var onEndEditing: () -> Void
        var onFocusChanged: (Bool) -> Void
        private var lastFocusNonce: Int?
        weak var field: KeyTextField?

        init(
            text: Binding<String>,
            onCommand: @escaping (UInt16) -> Bool,
            onEndEditing: @escaping () -> Void,
            onFocusChanged: @escaping (Bool) -> Void
        ) {
            self.text = text
            self.onCommand = onCommand
            self.onEndEditing = onEndEditing
            self.onFocusChanged = onFocusChanged
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            onFocusChanged(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            onFocusChanged(false)
            DispatchQueue.main.async { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.field?.currentEditor() == nil else {
                        return
                    }
                    self.onEndEditing()
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertTab(_:)):
                return onCommand(48)
            case #selector(NSResponder.insertNewline(_:)):
                return onCommand(36)
            case #selector(NSResponder.moveDown(_:)):
                return onCommand(125)
            case #selector(NSResponder.moveUp(_:)):
                return onCommand(126)
            case #selector(NSResponder.deleteBackward(_:)):
                return textView.string.isEmpty && onCommand(51)
            case #selector(NSResponder.cancelOperation(_:)):
                if onCommand(53) {
                    return true
                }
                (control as? KeyTextField)?.focusOwningPane()
                return true
            default:
                return false
            }
        }

        func consumeFocusNonce(_ focusNonce: Int) -> Bool {
            defer { lastFocusNonce = focusNonce }
            guard let lastFocusNonce else {
                return false
            }
            return focusNonce != lastFocusNonce
        }
    }

    final class KeyTextField: NSTextField {
        var onCommand: (UInt16) -> Bool = { _ in false }

        override func keyDown(with event: NSEvent) {
            if onCommand(event.keyCode) {
                return
            }
            if event.keyCode == 53 {
                focusOwningPane()
                return
            }
            super.keyDown(with: event)
        }

        func setEditorText(_ text: String) {
            if let editor = currentEditor() {
                if editor.string == text {
                    return
                }
                editor.string = text
                stringValue = text
                moveCaretToEnd()
                return
            }
            if stringValue != text {
                stringValue = text
            }
        }

        func focusEditorAtEnd() {
            if currentEditor() == nil {
                window?.makeFirstResponder(self)
            }
            moveCaretToEnd()
        }

        func focusOwningPane() {
            var candidate = superview
            var target: NSView?
            while let view = candidate {
                if view.acceptsFirstResponder {
                    target = view
                }
                candidate = view.superview
            }
            window?.makeFirstResponder(target)
        }

        private func moveCaretToEnd() {
            guard let editor = currentEditor() else {
                return
            }
            editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        }
    }
}

private extension ArtifactScope {
    static var dockCases: [ArtifactScope] {
        [.session, .all]
    }

    var title: String {
        switch self {
        case .session:
            return "Session"
        case .project:
            return "Project"
        case .all:
            return "All"
        }
    }

    var emptyTitle: String {
        switch self {
        case .session:
            return "No session artifacts."
        case .project:
            return "No project artifacts."
        case .all:
            return "No artifacts."
        }
    }

    var emptyDetail: String {
        switch self {
        case .session:
            return "Run qm artifact add from this session."
        case .project:
            return "No artifacts registered for this project."
        case .all:
            return "No artifacts registered yet."
        }
    }
}

private struct ArtifactRow: View {
    var artifact: ArtifactReference
    var projectTitle: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.label)
                        .font(AppFonts.body.swiftUI)
                        .foregroundStyle(selected ? AppPalette.bright.swiftUI : AppPalette.text.swiftUI)
                        .lineLimit(1)
                    HStack(spacing: Token.Spacing.inline) {
                        Text(projectTitle)
                            .font(AppFonts.monoSmall.swiftUI)
                            .foregroundStyle(AppPalette.dim.swiftUI)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let addedDate {
                            Text(addedDate)
                                .font(AppFonts.monoSmall.swiftUI)
                                .foregroundStyle(AppPalette.muted.swiftUI)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Token.Spacing.card)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .stroke(selected ? AppPalette.activeControlBorder.swiftUI : .clear, lineWidth: 1)
            )
            .cornerRadius(Token.Radius.control)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(artifact.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(artifact.label)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Open artifact")
    }

    private var accessibilityValue: String {
        var parts = [artifact.path]
        if artifact.missing {
            parts.append("Missing")
        }
        if selected {
            parts.append("Selected")
        }
        return parts.joined(separator: ", ")
    }

    private var addedDate: String? {
        let value = artifact.addedAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 10 else {
            return nil
        }
        let date = String(value.prefix(10))
        let parts = date.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              Int(parts[0]) != nil,
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }
        return date
    }

    private var iconColor: Color {
        if artifact.missing {
            return AppPalette.warn.swiftUI
        }
        return selected ? AppPalette.accent.swiftUI : AppPalette.muted.swiftUI
    }

    private var iconName: String {
        if artifact.missing {
            return "exclamationmark.triangle"
        }
        switch artifact.resolvedKind {
        case .html:
            return "doc.richtext"
        case .markdown:
            return "doc.text"
        case .image:
            return "photo"
        case .unsupported:
            return "questionmark.square.dashed"
        }
    }

    private var rowBackground: Color {
        selected ? AppPalette.selection.swiftUI : Color.clear
    }
}

private struct ArtifactViewerPane: View {
    var displayState: ArtifactViewerDisplayState
    var reloadNonce: Int
    var onOpenExternal: (URL) -> Void

    var body: some View {
        viewerContent
        .background(AppPalette.artifactViewerBackground.swiftUI)
    }

    @ViewBuilder
    private var viewerContent: some View {
        switch displayState {
        case .viewing(let artifact):
            switch artifact.resolvedKind {
            case .html:
                ArtifactWebView(
                    artifact: artifact,
                    reloadNonce: reloadNonce,
                    decideNavigation: ArtifactNavigationPolicy.decide,
                    openExternal: onOpenExternal
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .markdown:
                ArtifactMarkdownView(artifact: artifact, reloadNonce: reloadNonce)
            case .image:
                ArtifactImageView(artifact: artifact, reloadNonce: reloadNonce)
            case .unsupported:
                ArtifactStatusPane(
                    symbolName: "questionmark.square.dashed",
                    title: "Unsupported artifact",
                    message: "This artifact kind is not supported in this build.",
                    detail: artifact.kind
                )
            }
        case .noCurrentSession:
            ArtifactStatusPane(
                symbolName: "rectangle.slash",
                title: "No current session",
                message: "Select a running session in the tracker."
            )
        case .empty:
            ArtifactStatusPane(
                symbolName: "doc",
                title: "No artifacts",
                message: "Run qm artifact add from this session."
            )
        case .missing(let artifact):
            ArtifactStatusPane(
                symbolName: "exclamationmark.triangle",
                title: "Missing file",
                message: "This artifact pointed at a file that no longer exists.",
                detail: artifact.path
            )
        case .unsupported(let artifact):
            ArtifactStatusPane(
                symbolName: "questionmark.square.dashed",
                title: "Unsupported artifact",
                message: "This artifact kind is not supported in this build.",
                detail: artifact.kind
            )
        }
    }

}

struct ArtifactStatusPane: View {
    var symbolName: String
    var title: String
    var message: String
    var detail: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(AppPalette.muted.swiftUI)
            Text(title)
                .font(AppFonts.bodyBold.swiftUI)
                .foregroundStyle(AppPalette.bright.swiftUI)
            Text(message)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail)
                    .font(AppFonts.monoSmall.swiftUI)
                    .foregroundStyle(AppPalette.dim.swiftUI)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
        .background(AppPalette.artifactViewerBackground.swiftUI)
    }
}
