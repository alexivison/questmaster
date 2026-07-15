import AppKit
import Foundation
import MarkdownUI
import QuestmasterCore
import SwiftUI

struct ArtifactMarkdownView: View {
    var artifact: ArtifactReference
    var reloadNonce: Int

    @State private var markdown = ""
    @State private var error: String?
    @State private var watcher = ArtifactFileWatcher()

    var body: some View {
        ScrollView {
            if let error {
                Text(error)
                    .font(AppFonts.body.swiftUI)
                    .foregroundStyle(AppPalette.warn.swiftUI)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Token.Spacing.content)
                    .background(ArtifactMarkdownScrollBackground())
                    .textSelection(.enabled)
            } else {
                Markdown(markdown, baseURL: baseURL, imageBaseURL: baseURL)
                    .markdownTheme(.gitHub)
                    .markdownTextStyle {
                        BackgroundColor(Color.clear)
                    }
                    .markdownImageProvider(LocalMarkdownImageProvider())
                    .markdownInlineImageProvider(LocalMarkdownInlineImageProvider())
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(Token.Spacing.content)
                    .background(ArtifactMarkdownScrollBackground())
                    .textSelection(.enabled)
            }
        }
        .background(AppPalette.artifactViewerBackground.swiftUI)
        .onAppear(perform: start)
        .onDisappear { watcher.stop() }
        .onChange(of: artifact.path) { _, _ in start() }
        .onChange(of: reloadNonce) { _, _ in load() }
    }

    private var baseURL: URL {
        URL(fileURLWithPath: artifact.path).deletingLastPathComponent()
    }

    private func start() {
        load()
        watcher.start(path: artifact.path) { load() }
    }

    private func load() {
        do {
            markdown = try String(contentsOf: URL(fileURLWithPath: artifact.path), encoding: .utf8)
            error = nil
        } catch {
            markdown = ""
            self.error = error.localizedDescription
        }
    }
}

struct LocalMarkdownImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        if let url = LocalMarkdownImages.fileURL(url),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

struct LocalMarkdownInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image {
        guard let fileURL = LocalMarkdownImages.fileURL(url),
              let image = NSImage(contentsOf: fileURL) else {
            throw LocalMarkdownImageError.unavailable
        }
        return Image(nsImage: image)
    }
}

enum LocalMarkdownImages {
    static func fileURL(_ url: URL?) -> URL? {
        guard let absoluteURL = url?.absoluteURL,
              absoluteURL.isFileURL else {
            return nil
        }
        return absoluteURL
    }
}

private enum LocalMarkdownImageError: Error {
    case unavailable
}

private struct ArtifactMarkdownScrollBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = nsView.enclosingScrollView else {
                return
            }
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.backgroundColor = .clear
            scrollView.contentView.drawsBackground = false
            scrollView.contentView.backgroundColor = .clear
        }
    }
}
