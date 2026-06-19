import AppKit
import Foundation
import WebKit

enum QuestViewerCommand {
    case gateToggle
    case commentAdd
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
        switch type.lowercased() {
        case "quest":
            return "quest"
        case "html", "htm", "text/html", "workspace_html", "workspace-html", "file.html":
            return "html"
        default:
            return type.lowercased()
        }
    }

    private static func unsupportedPlan(for type: String) -> ItemViewerRenderPlan {
        .unsupported(message: "no viewer for type: \(type.isEmpty ? "unknown" : type)")
    }
}

final class ItemViewerSurface: NSView {
    private let nativeSurface = NativeTextSurface()
    private let webView: WKWebView
    private var currentQuest: QuestDocument?
    var onOpenItemID: ((String) -> Bool)?
    var onQuestCommand: ((QuestViewerCommand) -> Bool)?

    var onControlDirection: ((FocusDirection) -> Bool)? {
        didSet {
            nativeSurface.onControlDirection = onControlDirection
        }
    }

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
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
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.isHidden = true

        addSubview(nativeSurface)
        addSubview(webView)
        NSLayoutConstraint.activate([
            nativeSurface.topAnchor.constraint(equalTo: topAnchor),
            nativeSurface.leadingAnchor.constraint(equalTo: leadingAnchor),
            nativeSurface.trailingAnchor.constraint(equalTo: trailingAnchor),
            nativeSurface.bottomAnchor.constraint(equalTo: bottomAnchor),

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
        currentQuest = quest
        webView.isHidden = true
        nativeSurface.isHidden = false
        nativeSurface.setContent(QuestViewerRenderer.render(quest))
    }

    func showHTML(_ document: HTMLViewerDocument) {
        currentQuest = nil
        do {
            let loaded = try HTMLDocumentLoader.load(document)
            nativeSurface.isHidden = true
            webView.isHidden = false
            webView.loadHTMLString(loaded.html, baseURL: loaded.baseURL)
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
        switch key {
        case " ", "x":
            return onQuestCommand?(.gateToggle) ?? false
        case "m":
            return onQuestCommand?(.commentAdd) ?? false
        case "a":
            return onQuestCommand?(.approve) ?? false
        case "d":
            return onQuestCommand?(.done) ?? false
        case "w":
            return onQuestCommand?(.withdraw) ?? false
        default:
            return false
        }
    }
}

private enum HTMLDocumentLoader {
    static func load(_ document: HTMLViewerDocument) throws -> (html: String, baseURL: URL?) {
        if !document.html.isEmpty {
            return (wrap(document.html, title: document.title, baseURL: nil), nil)
        }

        if !document.path.isEmpty {
            let expandedPath = (document.path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedPath)
            let raw = try String(contentsOf: url, encoding: .utf8)
            return (wrap(raw, title: document.title.isEmpty ? url.lastPathComponent : document.title, baseURL: url.deletingLastPathComponent()), url.deletingLastPathComponent())
        }

        if !document.url.isEmpty, let url = URL(string: document.url) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            return (wrap(raw, title: document.title.isEmpty ? url.lastPathComponent : document.title, baseURL: url.deletingLastPathComponent()), url.deletingLastPathComponent())
        }

        throw ViewerError.emptyHTMLSource
    }

    private static func wrap(_ raw: String, title: String, baseURL: URL?) -> String {
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

    var errorDescription: String? {
        switch self {
        case .emptyHTMLSource:
            return "HTML item has no path, URL, or inline HTML."
        }
    }
}
