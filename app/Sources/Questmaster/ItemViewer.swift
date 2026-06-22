import AppKit
import Foundation
import QuestmasterCore

enum QuestViewerCommand {
    case gateToggle(gate: String)
    case commentAdd(anchor: String, body: String)
    case commentEdit(commentID: String, body: String)
    case commentDelete(commentID: String)
    case commentResolve(commentID: String)
    case openRelated(url: String)
    case approve
    case done
    case withdraw
}

final class ItemViewerSurface: NSView {
    private let nativeSurface = NativeTextSurface()
    private let commentComposerView = QuestCommentComposerView()
    private var currentQuest: QuestDocument?
    private var questFocusIndex: Int?
    private var renderedTargets: [QuestViewerRenderedTarget] = []
    private var commentComposer: QuestCommentComposerModel?
    private var renderedDetailKey: String?
    private let commentComposerHeight: CGFloat = 156
    var onQuestCommand: ((QuestViewerCommand) -> Bool)?
    var onBack: (() -> Bool)?

    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            nativeSurface.onControlDirection = onControlDirection
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor

        nativeSurface.translatesAutoresizingMaskIntoConstraints = false
        nativeSurface.onBareKey = { [weak self] key, _ in
            self?.handleQuestKey(key) ?? false
        }
        commentComposerView.onSubmit = { [weak self] in
            self?.submitCommentComposer() ?? false
        }
        commentComposerView.onCancel = { [weak self] in
            self?.closeCommentComposer(refocusDetail: true)
            return true
        }
        commentComposerView.translatesAutoresizingMaskIntoConstraints = false
        commentComposerView.isHidden = true

        addSubview(nativeSurface)
        NSLayoutConstraint.activate([
            nativeSurface.topAnchor.constraint(equalTo: topAnchor),
            nativeSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            nativeSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            nativeSurface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if isNativeRegionTabEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    func showQuest(_ quest: QuestDocument?) {
        let previousQuestID = currentQuest?.id
        currentQuest = quest
        if quest?.id != previousQuestID {
            questFocusIndex = nil
            renderedDetailKey = nil
            closeCommentComposer(refocusDetail: false, rerender: false)
        }
        if quest == nil {
            closeCommentComposer(refocusDetail: false, rerender: false)
        }
        nativeSurface.isHidden = false
        if renderedDetailKey == detailRenderKey(for: quest) {
            refreshFocusHighlight()
            return
        }
        renderCurrentQuest(keepFocusVisible: true)
    }

    func showStatus(title: String, message: String, detail: String) {
        showMessage(title: title, message: message, detail: detail, color: AppPalette.warn)
    }

    func focus(in window: NSWindow?) {
        nativeSurface.focus(in: window)
    }

    private func showMessage(title: String, message: String, detail: String, color: NSColor) {
        currentQuest = nil
        questFocusIndex = nil
        renderedTargets = []
        renderedDetailKey = nil
        closeCommentComposer(refocusDetail: false, rerender: false)
        nativeSurface.isHidden = false

        let out = AttributedText()
        out.append(title, color: AppPalette.bright, font: AppFonts.monoBold)
        out.newline()
        out.newline()
        out.append(message, color: color, font: AppFonts.monoBold)
        if !detail.isEmpty {
            out.newline()
            out.append(detail, color: AppPalette.muted, font: AppFonts.body)
        }
        nativeSurface.setInlineView(nil, range: nil, height: 0)
        nativeSurface.setContent(out.value)
    }

    private func handleQuestKey(_ key: String) -> Bool {
        guard currentQuest != nil else {
            return false
        }
        if commentComposer != nil {
            return false
        }
        if Keymap.Viewer.back.matches(key) {
            return onBack?() ?? true
        }
        if Keymap.Viewer.moveUpKeyCodes.matches(nativeSurfaceKeyCode(key))
            || Keymap.Viewer.moveUpCharacters.matches(key)
            || key == "up" {
            return moveQuestFocus(delta: -1)
        }
        if Keymap.Viewer.moveDownKeyCodes.matches(nativeSurfaceKeyCode(key))
            || Keymap.Viewer.moveDownCharacters.matches(key)
            || key == "down" {
            return moveQuestFocus(delta: 1)
        }
        if key == "page-up" {
            nativeSurface.scrollByPages(-1)
            syncFocusToVisibleTarget()
            return true
        }
        if key == "page-down" {
            nativeSurface.scrollByPages(1)
            syncFocusToVisibleTarget()
            return true
        }
        if Keymap.Viewer.gateToggle.matches(key) {
            return sendFocusedCommand(.gateToggle)
        }
        if Keymap.Viewer.commentAdd.matches(key) {
            return startCommentComposer()
        }
        if Keymap.Viewer.commentEdit.matches(key) {
            return startCommentEditComposer()
        }
        if Keymap.Viewer.commentDelete.matchesExactly(key) {
            return sendFocusedCommand(.commentDelete)
        }
        if Keymap.Viewer.commentResolve.matchesExactly(key) {
            return sendFocusedCommand(.commentResolve)
        }
        if Keymap.Viewer.openRelated.matches(key) {
            return sendFocusedCommand(.openRelated)
        }
        if Keymap.Viewer.approve.matches(key) {
            return onQuestCommand?(.approve) ?? false
        }
        if Keymap.Viewer.done.matches(key) {
            return onQuestCommand?(.done) ?? false
        }
        if Keymap.Viewer.withdraw.matches(key) {
            return onQuestCommand?(.withdraw) ?? false
        }
        return false
    }

    private func renderCurrentQuest(keepFocusVisible: Bool, preserveScroll: Bool = false) {
        guard let quest = currentQuest else {
            renderedTargets = []
            renderedDetailKey = detailRenderKey(for: nil)
            nativeSurface.setInlineView(nil, range: nil, height: 0)
            nativeSurface.setContent(QuestViewerRenderer.render(nil))
            return
        }
        let targets = QuestDetailCursorLogic.targets(in: quest)
        questFocusIndex = QuestDetailCursorLogic.validFocusIndex(questFocusIndex, targetCount: targets.count)
        let focusedTarget = questFocusIndex.map { targets[$0] }
        let rendered = QuestViewerRenderer.renderDetail(
            quest,
            focusedTarget: nil,
            inlineComposerTarget: commentComposer == nil ? nil : focusedTarget
        )
        renderedTargets = rendered.targets
        nativeSurface.setContent(rendered.content, preserveScroll: preserveScroll)
        let focusedRange = renderedRange(for: focusedTarget)
        if commentComposer == nil {
            nativeSurface.setInlineView(nil, range: nil, height: 0)
        } else {
            nativeSurface.setInlineView(
                commentComposerView,
                range: rendered.composerPlaceholderRange,
                height: commentComposerHeight
            )
        }
        renderedDetailKey = detailRenderKey(for: quest)
        if keepFocusVisible {
            if let composerRange = rendered.composerPlaceholderRange {
                nativeSurface.scrollRangeToVisible(composerRange)
            } else if let focusedRange {
                nativeSurface.scrollRangeToVisible(focusedRange)
            }
        }
        nativeSurface.updateFocusHighlight(previousRange: nil, focusedRange: focusedRange)
    }

    private func moveQuestFocus(delta: Int) -> Bool {
        guard let quest = currentQuest else {
            return false
        }
        let targets = QuestDetailCursorLogic.targets(in: quest)
        let previousTarget = questFocusIndex.flatMap { index in
            targets.indices.contains(index) ? targets[index] : nil
        }
        switch QuestDetailCursorLogic.move(focusIndex: questFocusIndex, targetCount: targets.count, delta: delta) {
        case .moved(let index):
            questFocusIndex = index
            let focusedTarget = targets[index]
            let previousRange = renderedRange(for: previousTarget)
            let focusedRange = renderedRange(for: focusedTarget)
            if let focusedRange {
                nativeSurface.scrollRangeToVisible(focusedRange)
            }
            nativeSurface.updateFocusHighlight(previousRange: previousRange, focusedRange: focusedRange)
        case .scroll:
            nativeSurface.scrollBy(lines: delta > 0 ? 1 : -1)
            syncFocusToVisibleTarget()
        }
        return true
    }

    private func syncFocusToVisibleTarget() {
        guard let quest = currentQuest,
              !renderedTargets.isEmpty,
              let visibleRange = nativeSurface.visibleCharacterRange() else {
            return
        }
        guard let renderedIndex = QuestDetailCursorLogic.visibleFocusIndex(
            targetRanges: renderedTargets.map(\.range),
            visibleRange: visibleRange
        ) else {
            return
        }
        let targets = QuestDetailCursorLogic.targets(in: quest)
        let previousTarget = questFocusIndex.flatMap { index in
            targets.indices.contains(index) ? targets[index] : nil
        }
        let target = renderedTargets[renderedIndex].target
        guard let index = targets.firstIndex(of: target), questFocusIndex != index else {
            return
        }
        questFocusIndex = index
        nativeSurface.updateFocusHighlight(
            previousRange: renderedRange(for: previousTarget),
            focusedRange: renderedTargets[renderedIndex].range
        )
    }

    private func focusedTarget(in quest: QuestDocument) -> QuestDetailTarget? {
        let targets = QuestDetailCursorLogic.targets(in: quest)
        questFocusIndex = QuestDetailCursorLogic.validFocusIndex(questFocusIndex, targetCount: targets.count)
        return questFocusIndex.map { targets[$0] }
    }

    private func refreshFocusHighlight() {
        guard let quest = currentQuest else {
            return
        }
        nativeSurface.updateFocusHighlight(previousRange: nil, focusedRange: renderedRange(for: focusedTarget(in: quest)))
    }

    private func renderedRange(for target: QuestDetailTarget?) -> NSRange? {
        guard let target else {
            return nil
        }
        return renderedTargets.first(where: { $0.target == target })?.range
    }

    private func detailRenderKey(for quest: QuestDocument?) -> String {
        let questKey = quest.map { String(reflecting: $0) } ?? "<nil>"
        let composerKey = commentComposer.map { String(reflecting: $0.mode) } ?? "<composer:nil>"
        return questKey + "\u{1e}" + composerKey
    }

    private func startCommentComposer() -> Bool {
        guard let quest = currentQuest else {
            return false
        }
        guard let anchor = QuestDetailCursorLogic.commentAddAnchor(focusedTarget: focusedTarget(in: quest), in: quest) else {
            return true
        }
        showCommentComposer(QuestCommentComposerModel(mode: .add(anchor: anchor)))
        return true
    }

    private func startCommentEditComposer() -> Bool {
        guard let quest = currentQuest,
              let action = QuestDetailCursorLogic.action(.commentEdit, focusedTarget: focusedTarget(in: quest), in: quest) else {
            return true
        }
        guard case .commentEdit(let commentID, let body) = action else {
            return true
        }
        showCommentComposer(QuestCommentComposerModel(mode: .edit(commentID: commentID), body: body))
        return true
    }

    private func showCommentComposer(_ composer: QuestCommentComposerModel) {
        commentComposer = composer
        commentComposerView.configure(
            title: composer.title,
            target: composer.targetLabel,
            body: composer.body,
            error: composer.errorMessage
        )
        commentComposerView.isHidden = false
        renderCurrentQuest(keepFocusVisible: true)
        commentComposerView.focus(in: window)
    }

    private func submitCommentComposer() -> Bool {
        guard var composer = commentComposer else {
            return false
        }
        composer.body = commentComposerView.body
        guard let payload = composer.submit() else {
            commentComposer = composer
            commentComposerView.setError(composer.errorMessage)
            NSSound.beep()
            return true
        }

        let sent: Bool
        switch payload.mode {
        case .add(let anchor):
            sent = onQuestCommand?(.commentAdd(anchor: anchor, body: payload.body)) ?? false
        case .edit(let commentID):
            sent = onQuestCommand?(.commentEdit(commentID: commentID, body: payload.body)) ?? false
        }
        if sent {
            closeCommentComposer(refocusDetail: true)
        }
        return true
    }

    private func closeCommentComposer(refocusDetail: Bool, rerender: Bool = true) {
        commentComposer = nil
        commentComposerView.clear()
        commentComposerView.isHidden = true
        nativeSurface.setInlineView(nil, range: nil, height: 0)
        if rerender {
            renderCurrentQuest(keepFocusVisible: false, preserveScroll: true)
        }
        if refocusDetail {
            nativeSurface.focus(in: window)
        }
    }

    private func sendFocusedCommand(_ command: QuestDetailCommand) -> Bool {
        guard let quest = currentQuest else {
            return false
        }
        let targets = QuestDetailCursorLogic.targets(in: quest)
        questFocusIndex = QuestDetailCursorLogic.validFocusIndex(questFocusIndex, targetCount: targets.count)
        let focusedTarget = questFocusIndex.map { targets[$0] }
        guard let action = QuestDetailCursorLogic.action(command, focusedTarget: focusedTarget, in: quest) else {
            return true
        }
        switch action {
        case .gateToggle(let gate):
            return onQuestCommand?(.gateToggle(gate: gate)) ?? false
        case .commentEdit(let commentID, let body):
            return onQuestCommand?(.commentEdit(commentID: commentID, body: body)) ?? false
        case .commentDelete(let commentID):
            return onQuestCommand?(.commentDelete(commentID: commentID)) ?? false
        case .commentResolve(let commentID):
            return onQuestCommand?(.commentResolve(commentID: commentID)) ?? false
        case .openRelated(let url):
            return onQuestCommand?(.openRelated(url: url)) ?? false
        }
    }

    private func nativeSurfaceKeyCode(_ key: String) -> UInt16 {
        switch key {
        case "up":
            return 126
        case "down":
            return 125
        default:
            return UInt16.max
        }
    }
}

private final class QuestCommentComposerView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let targetLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let textView = QuestCommentComposerTextView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: Keymap.CommentComposer.footerText)

    var onSubmit: (() -> Bool)?
    var onCancel: (() -> Bool)?

    var body: String {
        textView.string
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1

        titleLabel.font = AppFonts.monoBold
        titleLabel.textColor = AppPalette.bright
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        targetLabel.font = AppFonts.monoSmall
        targetLabel.textColor = AppPalette.dim
        targetLabel.lineBreakMode = .byTruncatingMiddle
        targetLabel.alignment = .right
        targetLabel.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        scrollView.layer?.backgroundColor = AppPalette.panelAlt.cgColor
        scrollView.layer?.borderColor = AppPalette.line.cgColor
        scrollView.layer?.borderWidth = 1
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = AppFonts.body
        textView.textColor = AppPalette.text
        textView.backgroundColor = AppPalette.panelAlt
        textView.insertionPointColor = AppPalette.warn
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.onSubmit = { [weak self] in self?.onSubmit?() ?? false }
        textView.onCancel = { [weak self] in self?.onCancel?() ?? false }
        scrollView.documentView = textView

        errorLabel.font = AppFonts.monoSmall
        errorLabel.textColor = AppPalette.deleted
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        footerLabel.font = AppFonts.monoSmall
        footerLabel.textColor = AppPalette.dim
        footerLabel.alignment = .right
        footerLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(targetLabel)
        addSubview(scrollView)
        addSubview(errorLabel)
        addSubview(footerLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: targetLabel.leadingAnchor, constant: -8),

            targetLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            targetLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            targetLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.48),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.heightAnchor.constraint(equalToConstant: 82),

            errorLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: footerLabel.leadingAnchor, constant: -8),

            footerLabel.centerYAnchor.constraint(equalTo: errorLabel.centerYAnchor),
            footerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            footerLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, target: String, body: String, error: String?) {
        titleLabel.stringValue = title
        targetLabel.stringValue = target
        textView.string = body
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        setError(error)
    }

    func setError(_ error: String?) {
        let message = error ?? ""
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
    }

    func clear() {
        textView.string = ""
        setError(nil)
    }

    func focus(in window: NSWindow?) {
        window?.makeFirstResponder(textView)
    }
}

private final class QuestCommentComposerTextView: NSTextView {
    var onSubmit: (() -> Bool)?
    var onCancel: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if Keymap.CommentComposer.cancel.matches(event.keyCode), onCancel?() == true {
            return
        }

        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags.contains(.option), Keymap.CommentComposer.newlineOptionEnter.matches(event.keyCode) {
            insertNewline(nil)
            return
        }
        if flags.contains(.control), Keymap.CommentComposer.newlineControlJ.matches(key) {
            insertNewline(nil)
            return
        }
        if flags.contains(.control), Keymap.CommentComposer.submitControlS.matches(key), onSubmit?() == true {
            return
        }
        if flags.subtracting(.shift).isEmpty,
           Keymap.CommentComposer.submitEnter.matches(event.keyCode),
           onSubmit?() == true {
            return
        }

        super.keyDown(with: event)
    }
}
