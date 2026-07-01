import AppKit
import Foundation
import QuestmasterCore

final class ItemViewerSurface: NSView {
    private let nativeSurface = NativeTextSurface()
    private let skeletonView = SkeletonPlaceholderView(kind: .questDetail)
    private let commentComposerView = QuestCommentComposerView()
    private var currentQuest: QuestDocument?
    private var questFocusIndex: Int?
    private var renderedTargets: [QuestViewerRenderedTarget] = []
    private var commentComposer: QuestCommentComposerModel?
    private var renderedDetailKey: String?
    private var detailTargetCacheKey: String?
    private var detailTargetCache: [QuestDetailTarget] = []
    private var renderGeneration = 0
    private let commentComposerHeight: CGFloat = 156
    var onQuestCommand: ((QuestViewerCommand) -> Bool)?
    var onBack: (() -> Bool)?
    var onFocusRequested: (() -> Void)? {
        didSet {
            nativeSurface.onFocusRequested = onFocusRequested
        }
    }

    var onControlDirection: ((NavigationDirection) -> Bool)? {
        didSet {
            nativeSurface.onControlDirection = onControlDirection
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = AppPalette.questViewerBackground.cgColor

        nativeSurface.translatesAutoresizingMaskIntoConstraints = false
        nativeSurface.onBareKey = { [weak self] key, _ in
            self?.handleQuestKey(key) ?? false
        }
        nativeSurface.onCharacterClick = { [weak self] characterIndex in
            self?.handleQuestClick(characterIndex: characterIndex) ?? false
        }
        nativeSurface.onFocusRequested = { [weak self] in
            self?.onFocusRequested?()
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
        skeletonView.translatesAutoresizingMaskIntoConstraints = false
        skeletonView.isHidden = true

        addSubview(skeletonView)
        addSubview(nativeSurface)
        NSLayoutConstraint.activate([
            skeletonView.topAnchor.constraint(equalTo: topAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: trailingAnchor),
            skeletonView.bottomAnchor.constraint(equalTo: bottomAnchor),

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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequested?()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isNativeRegionTabEvent(event) {
            return
        }
        super.keyDown(with: event)
    }

    func showQuest(_ quest: QuestDocument?) {
        skeletonView.isHidden = true
        let previousQuestID = currentQuest?.id
        currentQuest = quest
        let questChanged = quest?.id != previousQuestID
        if questChanged {
            invalidateScheduledRender()
            questFocusIndex = nil
            clearDetailRenderCache()
            closeCommentComposer(refocusDetail: false, rerender: false)
        }
        if quest == nil {
            closeCommentComposer(refocusDetail: false, rerender: false)
        }
        nativeSurface.isHidden = false
        let detailKey = detailRenderKey(for: quest)
        if renderedDetailKey == detailKey {
            invalidateScheduledRender()
            nativeSurface.refreshStableCursor()
            return
        }
        if questChanged {
            renderCurrentQuestNow(keepFocusVisible: true, knownDetailKey: detailKey)
        } else {
            scheduleRenderCurrentQuest(keepFocusVisible: true, detailKey: detailKey)
        }
    }

    func showStatus(title: String, message: String, detail: String) {
        invalidateScheduledRender()
        skeletonView.isHidden = true
        showMessage(title: title, message: message, detail: detail, color: AppPalette.warn)
    }

    func showSkeleton() {
        invalidateScheduledRender()
        currentQuest = nil
        questFocusIndex = nil
        renderedTargets = []
        clearDetailRenderCache()
        closeCommentComposer(refocusDetail: false, rerender: false)
        nativeSurface.isHidden = true
        skeletonView.isHidden = false
    }

    func focus(in window: NSWindow?) {
        nativeSurface.focus(in: window)
    }

    private func showMessage(title: String, message: String, detail: String, color: NSColor) {
        invalidateScheduledRender()
        currentQuest = nil
        questFocusIndex = nil
        renderedTargets = []
        clearDetailRenderCache()
        closeCommentComposer(refocusDetail: false, rerender: false)
        skeletonView.isHidden = true
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
        if Keymap.Viewer.backKeyCodes.matches(nativeSurfaceKeyCode(key))
            || Keymap.Viewer.back.matches(key) {
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

    private func handleQuestClick(characterIndex: Int) -> Bool {
        guard let quest = currentQuest,
              commentComposer == nil,
              let renderedIndex = QuestDetailCursorLogic.clickedFocusIndex(
                targetRanges: renderedTargets.map(\.range),
                characterIndex: characterIndex
              ) else {
            return false
        }

        nativeSurface.focus(in: window)
        guard focusRenderedTarget(at: renderedIndex, in: quest) != nil else {
            return false
        }
        let renderedTarget = renderedTargets[renderedIndex]
        guard renderedTarget.target.kind == .gate,
              characterIndex < renderedTarget.range.location + 2 else {
            return true
        }
        return sendFocusedCommand(.gateToggle)
    }

    private func renderCurrentQuest(keepFocusVisible: Bool, preserveScroll: Bool = false) {
        invalidateScheduledRender()
        renderCurrentQuestNow(keepFocusVisible: keepFocusVisible, preserveScroll: preserveScroll)
    }

    private func scheduleRenderCurrentQuest(keepFocusVisible: Bool, preserveScroll: Bool = false, detailKey: String? = nil) {
        renderGeneration += 1
        let generation = renderGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.renderGeneration == generation else {
                return
            }
            self.renderCurrentQuestNow(keepFocusVisible: keepFocusVisible, preserveScroll: preserveScroll, knownDetailKey: detailKey)
        }
    }

    private func invalidateScheduledRender() {
        renderGeneration += 1
    }

    private func renderCurrentQuestNow(keepFocusVisible: Bool, preserveScroll: Bool = false, knownDetailKey: String? = nil) {
        guard let quest = currentQuest else {
            renderedTargets = []
            let detailKey = knownDetailKey ?? detailRenderKey(for: nil)
            detailTargetCacheKey = detailKey
            detailTargetCache = []
            nativeSurface.setInlineView(nil, range: nil, height: 0)
            nativeSurface.setContent(QuestViewerRenderer.render(nil))
            renderedDetailKey = detailKey
            nativeSurface.refreshStableCursor()
            return
        }
        let detailKey = knownDetailKey ?? detailRenderKey(for: quest)
        let renderInputs = detailRenderInputs(for: quest, detailKey: detailKey)
        let targets = renderInputs.targets
        questFocusIndex = QuestDetailCursorLogic.validFocusIndex(questFocusIndex, targetCount: targets.count)
        let focusedTarget = questFocusIndex.map { targets[$0] }
        let rendered = QuestViewerRenderer.renderDetail(
            quest,
            focusedTarget: nil,
            inlineComposerTarget: commentComposer == nil ? nil : focusedTarget,
            focusableTargets: targets,
            commentBuckets: renderInputs.commentBuckets
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
        if keepFocusVisible {
            if let composerRange = rendered.composerPlaceholderRange {
                nativeSurface.scrollRangeToVisible(composerRange)
            } else if let focusedRange {
                nativeSurface.scrollRangeToVisible(focusedRange)
            }
        }
        nativeSurface.updateFocusHighlight(previousRange: nil, focusedRange: focusedRange)
        renderedDetailKey = detailKey
        nativeSurface.refreshStableCursor()
    }

    private func moveQuestFocus(delta: Int) -> Bool {
        guard let quest = currentQuest else {
            return false
        }
        let targets = detailTargets(for: quest)
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
        let targets = detailTargets(for: quest)
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

    @discardableResult
    private func focusRenderedTarget(at renderedIndex: Int, in quest: QuestDocument) -> QuestDetailTarget? {
        guard renderedTargets.indices.contains(renderedIndex) else {
            return nil
        }
        let target = renderedTargets[renderedIndex].target
        let targets = detailTargets(for: quest)
        guard let nextFocusIndex = targets.firstIndex(of: target) else {
            return nil
        }

        let previousTarget = questFocusIndex.flatMap { index in
            targets.indices.contains(index) ? targets[index] : nil
        }
        questFocusIndex = nextFocusIndex
        nativeSurface.updateFocusHighlight(
            previousRange: renderedRange(for: previousTarget),
            focusedRange: renderedTargets[renderedIndex].range
        )
        return target
    }

    private func focusedTarget(in quest: QuestDocument) -> QuestDetailTarget? {
        let targets = detailTargets(for: quest)
        questFocusIndex = QuestDetailCursorLogic.validFocusIndex(questFocusIndex, targetCount: targets.count)
        return questFocusIndex.map { targets[$0] }
    }

    private func renderedRange(for target: QuestDetailTarget?) -> NSRange? {
        guard let target else {
            return nil
        }
        return renderedTargets.first(where: { $0.target == target })?.range
    }

    private func detailRenderKey(for quest: QuestDocument?) -> String {
        QuestDetailRenderKey.key(for: quest, composerMode: commentComposer?.mode)
    }

    private func detailRenderInputs(
        for quest: QuestDocument,
        detailKey: String
    ) -> (targets: [QuestDetailTarget], commentBuckets: QuestDetailCursorLogic.CommentBuckets) {
        let commentBuckets = QuestDetailCursorLogic.commentBuckets(in: quest)
        if detailTargetCacheKey != detailKey {
            cacheDetailTargets(QuestDetailCursorLogic.targets(in: quest, commentBuckets: commentBuckets), key: detailKey)
        }
        return (detailTargetCache, commentBuckets)
    }

    private func detailTargets(for quest: QuestDocument) -> [QuestDetailTarget] {
        // Always derive the key from the quest passed in: renderedDetailKey can lag
        // currentQuest during the async-render window after a same-ID content update,
        // and trusting it would let a key command reuse stale targets and dispatch an
        // index-based action against the new content (toggling/deleting the wrong item).
        let detailKey = detailRenderKey(for: quest)
        guard detailTargetCacheKey != detailKey else {
            return detailTargetCache
        }
        let commentBuckets = QuestDetailCursorLogic.commentBuckets(in: quest)
        return cacheDetailTargets(QuestDetailCursorLogic.targets(in: quest, commentBuckets: commentBuckets), key: detailKey)
    }

    @discardableResult
    private func cacheDetailTargets(_ targets: [QuestDetailTarget], key: String) -> [QuestDetailTarget] {
        detailTargetCacheKey = key
        detailTargetCache = targets
        return targets
    }

    private func clearDetailRenderCache() {
        renderedDetailKey = nil
        detailTargetCacheKey = nil
        detailTargetCache = []
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
        let targets = detailTargets(for: quest)
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
        case "left":
            return 123
        case "up":
            return 126
        case "down":
            return 125
        default:
            return UInt16.max
        }
    }
}
