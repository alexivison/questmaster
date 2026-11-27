import MarkdownUI
import SwiftUI
import cmark_gfm
import cmark_gfm_extensions

struct ArtifactMarkdownPage: Identifiable {
    let id: Int
    let markdown: String
    let topSpacing: CGFloat
}

enum ArtifactMarkdownLayout {
    // Target small MarkdownUI stacks; a single large top-level block still stays intact.
    private static let pageByteLimit = 1_000

    static func pages(from markdown: String) -> [ArtifactMarkdownPage] {
        // Resolve reference-style links before splitting the document into independent pages.
        let normalized = MarkdownContent(markdown).renderMarkdown()
        guard !normalized.isEmpty else { return [] }
        guard let blocks = topLevelBlocks(in: normalized), !blocks.isEmpty else {
            return [ArtifactMarkdownPage(id: 0, markdown: normalized, topSpacing: 0)]
        }

        let sourceLines = MarkdownSourceLines(normalized)
        guard blocks.allSatisfy({ $0.endLine <= sourceLines.count }) else {
            return [ArtifactMarkdownPage(id: 0, markdown: normalized, topSpacing: 0)]
        }
        var groups: [[MarkdownBlockRange]] = []
        var group: [MarkdownBlockRange] = []
        var groupBytes = 0

        for block in blocks {
            let bytes = sourceLines.byteCount(startLine: block.startLine, endLine: block.endLine)
            if !group.isEmpty, groupBytes + bytes > pageByteLimit {
                groups.append(group)
                group = []
                groupBytes = 0
            }
            group.append(block)
            groupBytes += bytes + 2
        }
        if !group.isEmpty {
            groups.append(group)
        }

        var previousMargins: MarkdownBlockMargins?
        return groups.enumerated().map { index, group in
            let first = group[0]
            let last = group[group.count - 1]
            let source = sourceLines.text(startLine: first.startLine, endLine: last.endLine)
            let topSpacing = index == 0
                ? 0
                : max(previousMargins?.bottom ?? 0, first.margins.top ?? 0)
            previousMargins = last.margins
            return ArtifactMarkdownPage(
                id: index,
                markdown: source,
                topSpacing: topSpacing
            )
        }
    }

    private static func topLevelBlocks(in markdown: String) -> [MarkdownBlockRange]? {
        // MarkdownUI keeps block ranges private, so use its CMark/GFM parser configuration here.
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return nil }
        defer { cmark_parser_free(parser) }

        let extensions: Set<String> = ["autolink", "strikethrough", "tagfilter", "tasklist", "table"]
        for name in extensions {
            guard let syntaxExtension = cmark_find_syntax_extension(name) else { continue }
            cmark_parser_attach_syntax_extension(parser, syntaxExtension)
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }

        var blocks: [MarkdownBlockRange] = []
        var node = cmark_node_first_child(document)
        while let current = node {
            let startLine = Int(cmark_node_get_start_line(current))
            let endLine = Int(cmark_node_get_end_line(current))
            guard startLine > 0, endLine >= startLine else { return nil }
            blocks.append(
                MarkdownBlockRange(
                    startLine: startLine,
                    endLine: endLine,
                    margins: margins(of: current)
                )
            )
            node = cmark_node_next(current)
        }
        return blocks
    }

    private static func margins(of node: UnsafeMutablePointer<cmark_node>) -> MarkdownBlockMargins {
        let type = String(cString: cmark_node_get_type_string(node))
        switch type {
        // Keep these in sync with MarkdownUI's GitHub theme and this viewer's 16pt text.
        case "heading":
            return MarkdownBlockMargins(top: 24, bottom: 16)
        case "paragraph", "html_block", "code_block", "table":
            return MarkdownBlockMargins(top: 0, bottom: 16)
        case "thematic_break":
            return MarkdownBlockMargins(top: 24, bottom: 24)
        case "block_quote", "list", "item", "tasklist":
            var result = childMargins(of: node)
            if type == "item" || type == "tasklist" {
                result.top = max(result.top ?? 0, 4)
            }
            return result
        default:
            return childMargins(of: node)
        }
    }

    private static func childMargins(of node: UnsafeMutablePointer<cmark_node>) -> MarkdownBlockMargins {
        var result = MarkdownBlockMargins()
        var child = cmark_node_first_child(node)
        while let current = child {
            result.merge(margins(of: current))
            child = cmark_node_next(current)
        }
        return result
    }
}

private struct MarkdownBlockRange {
    let startLine: Int
    let endLine: Int
    let margins: MarkdownBlockMargins
}

private struct MarkdownSourceLines {
    private let source: String
    private let starts: [String.Index]

    var count: Int { starts.count }

    init(_ source: String) {
        self.source = source
        var starts = [source.startIndex]
        for index in source.utf8.indices where source.utf8[index] == 0x0A {
            starts.append(source.utf8.index(after: index))
        }
        self.starts = starts
    }

    func byteCount(startLine: Int, endLine: Int) -> Int {
        guard startLine > 0, startLine <= starts.count, endLine <= starts.count else { return 0 }
        let lower = starts[startLine - 1]
        let upper = endLine < starts.count ? starts[endLine] : source.endIndex
        return source.utf8.distance(from: lower, to: upper)
    }

    func text(startLine: Int, endLine: Int) -> String {
        guard startLine > 0, startLine <= starts.count, endLine <= starts.count else { return "" }
        let lower = starts[startLine - 1]
        let upper = endLine < starts.count
            ? source.utf8.index(before: starts[endLine])
            : source.endIndex
        return String(source[lower..<upper])
    }
}

private struct MarkdownBlockMargins {
    var top: CGFloat?
    var bottom: CGFloat?

    mutating func merge(_ other: MarkdownBlockMargins) {
        top = Self.maximum(top, other.top)
        bottom = Self.maximum(bottom, other.bottom)
    }

    private static func maximum(_ lhs: CGFloat?, _ rhs: CGFloat?) -> CGFloat? {
        switch (lhs, rhs) {
        case let (left?, right?): max(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }
}
