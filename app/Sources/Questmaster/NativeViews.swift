import AppKit
import QuestmasterCore

final class RegionView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let body: NSView

    init(title: String, body: NSView, background: NSColor = AppPalette.panel) {
        self.body = body
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = background.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = AppPalette.line.cgColor

        titleLabel.stringValue = title
        titleLabel.font = AppFonts.monoBold
        titleLabel.textColor = AppPalette.bright
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = AppFonts.monoSmall
        statusLabel.textColor = AppPalette.dim
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(body)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -8),

            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setStatus(_ status: String) {
        statusLabel.stringValue = status
    }

    func setFocused(_ focused: Bool) {
        layer?.borderWidth = focused ? 2 : 1
        layer?.borderColor = (focused ? AppPalette.accent : AppPalette.line).cgColor
        titleLabel.textColor = focused ? AppPalette.accent : AppPalette.bright
    }
}

final class NativeTextSurface: NSView {
    private let scrollView = NSScrollView()
    private let textView = KeyHandlingTextView()
    private var inlineView: NSView?
    private var inlineViewRange: NSRange?
    private var inlineViewHeight: CGFloat = 0
    var onOpenLink: ((URL) -> Bool)?
    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            textView.onControlDirection = onControlDirection
        }
    }
    var onBareKey: ((String, NSEvent) -> Bool)? {
        didSet {
            textView.onBareKey = onBareKey
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: 0x0f1316).cgColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(hex: 0x0f1316)
        textView.textColor = AppPalette.text
        textView.font = AppFonts.mono
        textView.textContainerInset = NSSize(width: 22, height: 20)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func layout() {
        super.layout()
        updateTextViewWidth()
        updateInlineViewFrame()
    }

    override func keyDown(with event: NSEvent) {
        if isNativeRegionTabEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    func setContent(_ content: NSAttributedString, preserveScroll: Bool = false) {
        let origin = scrollView.contentView.bounds.origin
        textView.suppressesScrollRangeToVisible = preserveScroll
        updateTextViewWidth()
        textView.textStorage?.setAttributedString(content)
        updateTextViewWidth()
        if preserveScroll {
            restoreScrollOrigin(origin)
            DispatchQueue.main.async { [weak self] in
                self?.restoreScrollOrigin(origin)
                self?.textView.suppressesScrollRangeToVisible = false
            }
        } else {
            textView.suppressesScrollRangeToVisible = false
        }
        updateInlineViewFrame()
    }

    func updateFocusHighlight(previousRange: NSRange?, focusedRange: NSRange?) {
        guard previousRange != focusedRange,
              let textStorage = textView.textStorage else {
            return
        }

        let origin = scrollView.contentView.bounds.origin
        textView.suppressesScrollRangeToVisible = true
        textStorage.beginEditing()
        if let previousRange = boundedRange(previousRange, in: textStorage) {
            textStorage.removeAttribute(.backgroundColor, range: previousRange)
        }
        if let focusedRange = boundedRange(focusedRange, in: textStorage) {
            textStorage.addAttribute(.backgroundColor, value: AppPalette.selection, range: focusedRange)
        }
        textStorage.endEditing()
        restoreScrollOrigin(origin)
        DispatchQueue.main.async { [weak self] in
            self?.restoreScrollOrigin(origin)
            self?.textView.suppressesScrollRangeToVisible = false
        }
        updateInlineViewFrame()
    }

    func scrollBy(lines: CGFloat) {
        scrollBy(points: lines * 18)
    }

    func scrollByPages(_ pages: CGFloat) {
        let height = scrollView.contentView.bounds.height
        scrollBy(points: pages * max(60, height * 0.82))
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard range.location != NSNotFound, range.length >= 0 else {
            return
        }
        let wasSuppressing = textView.suppressesScrollRangeToVisible
        textView.suppressesScrollRangeToVisible = false
        textView.scrollRangeToVisible(range)
        textView.suppressesScrollRangeToVisible = wasSuppressing
        updateInlineViewFrame()
    }

    func visibleCharacterRange() -> NSRange? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return nil
        }
        updateTextViewWidth()
        layoutManager.ensureLayout(for: textContainer)
        var rect = scrollView.contentView.bounds
        let origin = textView.textContainerOrigin
        rect.origin.x -= origin.x
        rect.origin.y -= origin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: textContainer)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    func setInlineView(_ view: NSView?, range: NSRange?, height: CGFloat) {
        if inlineView !== view {
            inlineView?.removeFromSuperview()
        }
        inlineView = view
        inlineViewRange = range
        inlineViewHeight = height
        guard let view, range != nil else {
            view?.isHidden = true
            return
        }
        view.translatesAutoresizingMaskIntoConstraints = true
        if view.superview !== textView {
            view.removeFromSuperview()
            textView.addSubview(view)
        }
        view.isHidden = false
        updateInlineViewFrame()
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(textView)
    }

    private func updateTextViewWidth() {
        let clipWidth = scrollView.contentView.bounds.width
        guard clipWidth > 0 else {
            return
        }
        textView.textContainer?.containerSize = NSSize(width: clipWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = clipWidth
        updateInlineViewFrame()
    }

    private func scrollBy(points: CGFloat) {
        let clipView = scrollView.contentView
        let maxY = max(0, textView.bounds.height - clipView.bounds.height)
        let nextY = min(max(0, clipView.bounds.origin.y + points), maxY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: nextY))
        scrollView.reflectScrolledClipView(clipView)
        updateInlineViewFrame()
    }

    private func restoreScrollOrigin(_ origin: NSPoint) {
        let clipView = scrollView.contentView
        let maxX = max(0, textView.bounds.width - clipView.bounds.width)
        let maxY = max(0, textView.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(
            x: min(max(0, origin.x), maxX),
            y: min(max(0, origin.y), maxY)
        ))
        scrollView.reflectScrolledClipView(clipView)
        updateInlineViewFrame()
    }

    private func boundedRange(_ range: NSRange?, in textStorage: NSTextStorage) -> NSRange? {
        guard let range,
              range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              range.location < textStorage.length else {
            return nil
        }
        return NSRange(location: range.location, length: min(range.length, textStorage.length - range.location))
    }

    private func updateInlineViewFrame() {
        guard let view = inlineView,
              let range = inlineViewRange,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage,
              textStorage.length > 0,
              range.location >= 0,
              range.location < textStorage.length else {
            inlineView?.isHidden = true
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: range.location)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let origin = textView.textContainerOrigin
        let inset = max(8, textView.textContainerInset.width)
        let width = max(120, textView.bounds.width - (inset * 2))
        view.frame = NSRect(
            x: inset,
            y: origin.y + lineRect.minY,
            width: width,
            height: inlineViewHeight
        )
        view.isHidden = false
    }
}

extension NativeTextSurface: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL {
            return onOpenLink?(url) ?? false
        }
        if let raw = link as? String, let url = URL(string: raw) {
            return onOpenLink?(url) ?? false
        }
        return false
    }
}

private final class FixedLeadingSplitView: NSView {
    private let preferredLeadingWidth: CGFloat
    private let dividerWidth: CGFloat = 1
    private let divider = NSView()
    private var panes: [NSView] = []

    init(preferredLeadingWidth: CGFloat) {
        self.preferredLeadingWidth = preferredLeadingWidth
        super.init(frame: .zero)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor(hex: 0x23282e).cgColor
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func addArrangedSubview(_ view: NSView) {
        panes.append(view)
        addSubview(view, positioned: .below, relativeTo: divider)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        applyFixedLayout()
    }

    func applyFixedLayout() {
        guard panes.count == 2, bounds.width > 0 else {
            return
        }

        let availableWidth = max(0, bounds.width - dividerWidth)
        let leadingWidth = min(availableWidth, min(preferredLeadingWidth, max(160, availableWidth * 0.62)))
        let height = bounds.height

        panes[0].frame = NSRect(x: 0, y: 0, width: leadingWidth, height: height)
        divider.frame = NSRect(x: leadingWidth, y: 0, width: dividerWidth, height: height)
        panes[1].frame = NSRect(
            x: leadingWidth + dividerWidth,
            y: 0,
            width: max(0, bounds.width - leadingWidth - dividerWidth),
            height: height
        )

        for view in panes {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
    }
}

final class DockView: NSView {
    let questListView = QuestBoardListView()
    let itemViewerSurface = ItemViewerSurface()
    var onMutationRequest: ((ServeMutationRequest, String) -> Void)?
    var onBoardSectionChanged: ((QuestBoardSection) -> Void)?
    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            questListView.onControlDirection = onControlDirection
            itemViewerSurface.onControlDirection = onControlDirection
        }
    }

    private let splitView = FixedLeadingSplitView(preferredLeadingWidth: 196)
    private var snapshot: RuntimeSnapshot?
    private var selectedQuestID: String?
    private var selectedSection: QuestBoardSection = .active
    private var userSelectedQuest = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        questListView.onSelectionChanged = { [weak self] questID in
            guard let self else {
                return
            }
            self.selectedQuestID = questID
            self.userSelectedQuest = true
            self.renderViewer()
        }
        questListView.onOpenQuest = { [weak self] questID in
            guard let self else {
                return
            }
            self.selectedQuestID = questID
            self.userSelectedQuest = true
            self.renderViewer()
            self.focusViewer(in: self.window)
        }
        questListView.onSectionChanged = { [weak self] section in
            guard let self else {
                return
            }
            self.selectedSection = section
            if let snapshot = self.snapshot {
                self.selectedQuestID = QuestBoardRenderer.validSelectionID(
                    in: snapshot,
                    preferredID: self.selectedQuestID,
                    selectedSection: section
                )
            }
            self.userSelectedQuest = true
            self.onBoardSectionChanged?(section)
            self.renderViewer()
        }
        questListView.onDeleteQuest = { [weak self] quest in
            self?.deleteQuest(quest) ?? false
        }
        itemViewerSurface.onQuestCommand = { [weak self] command in
            self?.handleQuestCommand(command) ?? false
        }
        itemViewerSurface.onBack = { [weak self] in
            guard let self else {
                return false
            }
            self.renderViewer()
            self.focusBoard(in: self.window)
            return true
        }

        splitView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(splitView)

        splitView.addArrangedSubview(questListView)
        splitView.addArrangedSubview(itemViewerSurface)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: topAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        DispatchQueue.main.async {
            self.splitView.applyFixedLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSnapshot(_ snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
        let preferredID = userSelectedQuest ? selectedQuestID : (snapshot.activeQuestID ?? selectedQuestID)
        selectedQuestID = QuestBoardRenderer.validSelectionID(in: snapshot, preferredID: preferredID, selectedSection: selectedSection)
        renderBoard()
        renderViewer()
    }

    func focusBoard(in window: NSWindow?) {
        questListView.focus(in: window)
    }

    func focusViewer(in window: NSWindow?) {
        itemViewerSurface.focus(in: window)
    }

    var statusText: String {
        return selectedQuestID ?? ""
    }

    var currentSection: QuestBoardSection {
        selectedSection
    }

    func selectSection(_ section: QuestBoardSection) {
        questListView.selectSection(section)
    }

    private func renderBoard() {
        guard let snapshot else {
            questListView.setSnapshot(.empty(sourceLabel: ""), selectedQuestID: nil, selectedSection: selectedSection)
            return
        }
        questListView.setSnapshot(snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
    }

    private func renderViewer() {
        guard let snapshot else {
            itemViewerSurface.showQuest(nil)
            return
        }
        if let message = snapshot.serviceStateMessage {
            if isServeStartingMessage(message) {
                itemViewerSurface.showSkeleton()
                return
            }
            itemViewerSurface.showStatus(
                title: "Quest detail",
                message: message,
                detail: "Waiting for qm serve; no fabricated data is shown."
            )
            return
        }
        let quest = QuestBoardRenderer.selectedQuest(in: snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
        itemViewerSurface.showQuest(quest)
    }

    private func currentQuest() -> QuestDocument? {
        guard let snapshot else {
            return nil
        }
        return QuestBoardRenderer.selectedQuest(in: snapshot, selectedQuestID: selectedQuestID, selectedSection: selectedSection)
    }

    private func deleteQuest(_ quest: QuestDocument) -> Bool {
        guard MutationPrompts.confirm(.deleteQuest(questID: quest.id, title: quest.title), relativeTo: window) else {
            return true
        }
        emitMutation(label: "delete quest \(quest.id)") {
            try ServeMutationRequests.questDelete(questID: quest.id)
        }
        return true
    }

    private func handleQuestCommand(_ command: QuestViewerCommand) -> Bool {
        guard let quest = currentQuest() else {
            return false
        }
        switch command {
        case .gateToggle(let gate):
            emitMutation(label: "toggle \(gate)") {
                try ServeMutationRequests.questGateToggle(questID: quest.id, gate: gate)
            }
        case .commentAdd(let anchor, let body):
            emitMutation(label: "comment \(quest.id)") {
                try ServeMutationRequests.questCommentAdd(questID: quest.id, anchor: anchor, body: body)
            }
        case .commentEdit(let commentID, let body):
            emitMutation(label: "edit comment \(commentID)") {
                try ServeMutationRequests.questCommentEdit(questID: quest.id, commentID: commentID, body: body)
            }
        case .commentDelete(let commentID):
            guard MutationPrompts.confirm(.deleteComment(questID: quest.id, commentID: commentID), relativeTo: window) else {
                return true
            }
            emitMutation(label: "delete comment \(commentID)") {
                try ServeMutationRequests.questCommentDelete(questID: quest.id, commentID: commentID)
            }
        case .commentResolve(let commentID):
            emitMutation(label: "resolve comment \(commentID)") {
                try ServeMutationRequests.questCommentResolve(questID: quest.id, commentID: commentID)
            }
        case .openRelated(let rawURL):
            guard let url = URL(string: rawURL) else {
                return true
            }
            NSWorkspace.shared.open(url)
        case .approve:
            emitMutation(label: "approve \(quest.id)") {
                try ServeMutationRequests.questStatus(questID: quest.id, status: "active")
            }
        case .done:
            guard MutationPrompts.confirm(.markQuestDone(questID: quest.id, title: quest.title), relativeTo: window) else {
                return true
            }
            emitMutation(label: "done \(quest.id)") {
                try ServeMutationRequests.questStatus(questID: quest.id, status: "done")
            }
        case .withdraw:
            emitMutation(label: "withdraw \(quest.id)") {
                try ServeMutationRequests.questStatus(questID: quest.id, status: "wip")
            }
        }
        return true
    }

    private func emitMutation(label: String, build: () throws -> ServeMutationRequest) {
        do {
            onMutationRequest?(try build(), label)
        } catch {
            NSSound.beep()
        }
    }
}
