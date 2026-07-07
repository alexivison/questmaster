import AppKit
import QuestmasterCore
import SwiftUI

struct ArtifactImageView: View {
    var artifact: ArtifactReference
    var reloadNonce: Int

    @State private var image: NSImage?
    @State private var error: String?
    @State private var watcher = ArtifactFileWatcher()

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(Token.Spacing.content)
            } else {
                ArtifactStatusPane(
                    symbolName: "photo",
                    title: "Image unavailable",
                    message: error ?? "This image could not be opened.",
                    detail: artifact.path
                )
            }
        }
        .background(AppPalette.artifactViewerBackground.swiftUI)
        .onAppear(perform: start)
        .onDisappear { watcher.stop() }
        .onChange(of: artifact.path) { _, _ in start() }
        .onChange(of: reloadNonce) { _, _ in load() }
    }

    private func start() {
        load()
        watcher.start(path: artifact.path) { load() }
    }

    private func load() {
        if let image = NSImage(contentsOfFile: artifact.path) {
            self.image = image
            error = nil
        } else {
            image = nil
            error = "This image could not be opened."
        }
    }
}
