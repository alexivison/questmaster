import AppKit
import Foundation
import QuestmasterCore
import WebKit

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

struct ViewerItem {
    var type: String
    var title: String
    var quest: QuestDocument?
    var html: HTMLViewerDocument?

    static func quest(_ quest: QuestDocument?) -> ViewerItem {
        ViewerItem(type: "quest", title: quest?.title ?? "Quest", quest: quest, html: nil)
    }

    static func runtime(_ item: RuntimeViewerItem, snapshot: RuntimeSnapshot) -> ViewerItem {
        let type = item.normalizedType
        if type == "quest" {
            let quest = snapshot.board.quest(id: item.questID) ?? snapshot.selectedQuest
            return ViewerItem(type: "quest", title: quest?.title ?? item.title, quest: quest, html: nil)
        }
        return ViewerItem(
            type: type,
            title: item.title,
            quest: nil,
            html: HTMLViewerDocument(title: item.title, path: item.path, url: item.url, html: item.html)
        )
    }
}

struct HTMLViewerDocument {
    var title: String
    var path: String
    var url: String
    var html: String
}

enum ItemViewerRenderPlan: Equatable {
    case quest
    case html
    case unsupported(message: String)
}

enum ItemViewerRegistry {
    static func render(_ item: ViewerItem, in surface: ItemViewerSurface) {
        switch plan(for: item) {
        case .quest:
            surface.showQuest(item.quest)
        case .html:
            if let html = item.html {
                surface.showHTML(html)
            } else {
                surface.showUnsupported(type: item.type, title: item.title)
            }
        case .unsupported:
            surface.showUnsupported(type: item.type, title: item.title)
        }
    }

    static func plan(for item: ViewerItem) -> ItemViewerRenderPlan {
        switch normalizedType(item.type) {
        case "quest":
            return .quest
        case "html":
            return item.html == nil
                ? unsupportedPlan(for: item.type)
                : .html
        default:
            return unsupportedPlan(for: item.type)
        }
    }

    static func normalizedType(_ type: String) -> String {
        RuntimeViewerTypeNormalizer.normalizedType(type)
    }

    private static func unsupportedPlan(for type: String) -> ItemViewerRenderPlan {
        .unsupported(message: "no viewer for type: \(type.isEmpty ? "unknown" : type)")
    }
}

final class ItemViewerSurface: NSView {
    private let nativeSurface = NativeTextSurface()
    private let commentComposerView = QuestCommentComposerView()
    private let htmlNavigationGuard = HTMLNavigationGuard()
    private let webView: WKWebView
    private var currentQuest: QuestDocument?
    private var questFocusIndex: Int?
    private var renderedTargets: [QuestViewerRenderedTarget] = []
    private var commentComposer: QuestCommentComposerModel?
    private var commentComposerHeightConstraint: NSLayoutConstraint?
    var onOpenItemID: ((String) -> Bool)?
    var onQuestCommand: ((QuestViewerCommand) -> Bool)?
    var onBack: (() -> Bool)?

    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            nativeSurface.onControlDirection = onControlDirection
        }
    }

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptEnabled = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor

        nativeSurface.translatesAutoresizingMaskIntoConstraints = false
        nativeSurface.onOpenLink = { [weak self] url in
            guard url.scheme == "questmaster-item" else {
                return false
            }
            let raw = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !raw.isEmpty else {
                return false
            }
            return self?.onOpenItemID?(raw) ?? false
        }
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
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = htmlNavigationGuard
        webView.isHidden = true

        addSubview(nativeSurface)
        addSubview(commentComposerView)
        addSubview(webView)
        let composerHeight = commentComposerView.heightAnchor.constraint(equalToConstant: 0)
        commentComposerHeightConstraint = composerHeight
        NSLayoutConstraint.activate([
            nativeSurface.topAnchor.constraint(equalTo: topAnchor),
            nativeSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            nativeSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            nativeSurface.bottomAnchor.constraint(equalTo: commentComposerView.topAnchor),

            commentComposerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            commentComposerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            commentComposerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            composerHeight,

            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    func show(_ item: ViewerItem) {
        ItemViewerRegistry.render(item, in: self)
    }

    func showQuest(_ quest: QuestDocument?) {
        let previousQuestID = currentQuest?.id
        currentQuest = quest
        if quest?.id != previousQuestID {
            questFocusIndex = nil
            closeCommentComposer(refocusDetail: false)
        }
        if quest == nil {
            closeCommentComposer(refocusDetail: false)
        }
        webView.isHidden = true
        nativeSurface.isHidden = false
        renderCurrentQuest(keepFocusVisible: true)
    }

    func showHTML(_ document: HTMLViewerDocument) {
        currentQuest = nil
        questFocusIndex = nil
        renderedTargets = []
        closeCommentComposer(refocusDetail: false)
        do {
            let loaded = try HTMLDocumentLoader.load(document)
            nativeSurface.isHidden = true
            webView.isHidden = false
            webView.stopLoading()
            htmlNavigationGuard.allowInitialLoad()
            switch loaded {
            case .inlineHTML(let html):
                webView.loadHTMLString(html, baseURL: nil)
            case .file(let url):
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            case .remote(let url):
                webView.load(URLRequest(url: url))
            }
        } catch {
            showMessage(
                title: "Item viewer - HTML viewer",
                message: "Could not load HTML item.",
                detail: error.localizedDescription,
                color: AppPalette.deleted
            )
        }
    }

    func showUnsupported(type: String, title: String) {
        currentQuest = nil
        questFocusIndex = nil
        renderedTargets = []
        closeCommentComposer(refocusDetail: false)
        showMessage(
            title: title.isEmpty ? "Item viewer" : title,
            message: "no viewer for type: \(type.isEmpty ? "unknown" : type)",
            detail: "The item viewer registry has no renderer for this type.",
            color: AppPalette.warn
        )
    }

    func showStatus(title: String, message: String, detail: String) {
        showMessage(title: title, message: message, detail: detail, color: AppPalette.warn)
    }

    func focus(in window: NSWindow?) {
        if webView.isHidden {
            nativeSurface.focus(in: window)
        } else {
            window?.makeFirstResponder(webView)
        }
    }

    private func showMessage(title: String, message: String, detail: String, color: NSColor) {
        currentQuest = nil
        questFocusIndex = nil
        renderedTargets = []
        closeCommentComposer(refocusDetail: false)
        webView.isHidden = true
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
            return true
        }
        if key == "page-down" {
            nativeSurface.scrollByPages(1)
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

    private func renderCurrentQuest(keepFocusVisible: Bool) {
        guard let quest = currentQuest else {
            renderedTargets = []
            nativeSurface.setContent(QuestViewerRenderer.render(nil))
            return
        }
        let targets = QuestDetailCursorLogic.targets(in: quest)
        questFocusIndex = QuestDetailCursorLogic.validFocusIndex(questFocusIndex, targetCount: targets.count)
        let focusedTarget = questFocusIndex.map { targets[$0] }
        let rendered = QuestViewerRenderer.renderDetail(quest, focusedTarget: focusedTarget)
        renderedTargets = rendered.targets
        nativeSurface.setContent(rendered.content)
        guard keepFocusVisible, let focusedTarget else {
            return
        }
        if let renderedTarget = renderedTargets.first(where: { $0.target == focusedTarget }) {
            nativeSurface.scrollRangeToVisible(renderedTarget.range)
        }
    }

    private func moveQuestFocus(delta: Int) -> Bool {
        guard let quest = currentQuest else {
            return false
        }
        let targetCount = QuestDetailCursorLogic.targets(in: quest).count
        switch QuestDetailCursorLogic.move(focusIndex: questFocusIndex, targetCount: targetCount, delta: delta) {
        case .moved(let index):
            questFocusIndex = index
            renderCurrentQuest(keepFocusVisible: true)
        case .scroll:
            nativeSurface.scrollBy(lines: delta > 0 ? 1 : -1)
        }
        return true
    }

    private func focusedTarget(in quest: QuestDocument) -> QuestDetailTarget? {
        let targets = QuestDetailCursorLogic.targets(in: quest)
        questFocusIndex = QuestDetailCursorLogic.validFocusIndex(questFocusIndex, targetCount: targets.count)
        return questFocusIndex.map { targets[$0] }
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
        setCommentComposerVisible(true)
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

    private func closeCommentComposer(refocusDetail: Bool) {
        commentComposer = nil
        commentComposerView.clear()
        setCommentComposerVisible(false)
        if refocusDetail {
            nativeSurface.focus(in: window)
        }
    }

    private func setCommentComposerVisible(_ visible: Bool) {
        commentComposerView.isHidden = !visible
        commentComposerHeightConstraint?.constant = visible ? 156 : 0
        needsLayout = true
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

private final class HTMLNavigationGuard: NSObject, WKNavigationDelegate {
    private var allowNextMainFrameLoad = false

    func allowInitialLoad() {
        allowNextMainFrameLoad = true
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if allowNextMainFrameLoad {
            allowNextMainFrameLoad = false
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
    }
}

private enum HTMLDocumentLoader {
    enum LoadedDocument {
        case inlineHTML(String)
        case file(URL)
        case remote(URL)
    }

    static func load(_ document: HTMLViewerDocument) throws -> LoadedDocument {
        if !document.html.isEmpty {
            return .inlineHTML(wrap(document.html, title: document.title))
        }

        if !document.path.isEmpty {
            let expandedPath = (document.path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath).standardizedFileURL
            try validateLocalFile(url)
            return .file(url)
        }

        if !document.url.isEmpty, let url = URL(string: document.url) {
            if url.isFileURL {
                let fileURL = url.standardizedFileURL
                try validateLocalFile(fileURL)
                return .file(fileURL)
            }
            switch url.scheme?.lowercased() {
            case "http", "https":
                return .remote(url)
            case .some(let scheme):
                throw ViewerError.unsupportedHTMLURLScheme(scheme)
            case .none:
                throw ViewerError.invalidHTMLURL(document.url)
            }
        }

        throw ViewerError.emptyHTMLSource
    }

    private static func validateLocalFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile != true {
            throw ViewerError.unreadableHTMLFile(url.path)
        }
    }

    private static func wrap(_ raw: String, title: String) -> String {
        let css = """
        <style>
        :root{--doc-bg:#f4f1e9;--doc-ink:#26221c;--doc-dim:#6b6457;--doc-line:#ded6c5;--doc-code:#e7e0cf;}
        html,body{background:var(--doc-bg);color:var(--doc-ink);margin:0;}
        body{font:13.5px/1.55 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;padding:22px;}
        main{max-width:720px;margin:0 auto;}
        h1,h2,h3{line-height:1.18;color:#1f1b16;}
        a{color:#5b6e8c;}
        code{font-family:"SF Mono",Menlo,monospace;background:var(--doc-code);padding:1px 5px;border-radius:4px;}
        pre{background:var(--doc-code);border:1px solid var(--doc-line);border-radius:6px;padding:12px;overflow:auto;}
        table{border-collapse:collapse;width:100%;}
        th,td{border:1px solid var(--doc-line);padding:6px 8px;}
        img,svg,canvas,video{max-width:100%;height:auto;}
        blockquote{border-left:3px solid var(--doc-line);margin-left:0;padding-left:14px;color:var(--doc-dim);}
        </style>
        """
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: "<html", options: [.caseInsensitive]) != nil {
            return inject(css: css, intoHTMLDocument: raw)
        }
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escapeHTML(title.isEmpty ? "HTML item" : title))</title>
        \(css)
        </head>
        <body><main>\(raw)</main></body>
        </html>
        """
    }

    private static func inject(css: String, intoHTMLDocument html: String) -> String {
        if let headEnd = html.range(of: "</head>", options: [.caseInsensitive]) {
            var copy = html
            copy.insert(contentsOf: css, at: headEnd.lowerBound)
            return copy
        }
        if let bodyStart = html.range(of: "<body", options: [.caseInsensitive]),
           let close = html[bodyStart.lowerBound...].firstIndex(of: ">") {
            var copy = html
            copy.insert(contentsOf: css, at: html.index(after: close))
            return copy
        }
        return css + html
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private enum ViewerError: LocalizedError {
    case emptyHTMLSource
    case invalidHTMLURL(String)
    case unsupportedHTMLURLScheme(String)
    case unreadableHTMLFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyHTMLSource:
            return "HTML item has no path, URL, or inline HTML."
        case .invalidHTMLURL(let raw):
            return "HTML item URL is invalid: \(raw)"
        case .unsupportedHTMLURLScheme(let scheme):
            return "HTML item URL scheme is unsupported: \(scheme)"
        case .unreadableHTMLFile(let path):
            return "HTML item path is not a regular file: \(path)"
        }
    }
}
