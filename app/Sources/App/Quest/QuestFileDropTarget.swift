import AppKit
import QuestmasterCore
import SwiftUI

/// AppKit must register the same native types as the terminal, including screenshot file promises.
struct QuestFileDropTarget<Content: View>: NSViewRepresentable {
    var canAccept: () -> Bool
    var onTargeted: (Bool) -> Void
    var onReceiving: (Bool) -> Void
    var onDrop: ([URL], URL?) -> Bool
    var onError: (String) -> Void
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> QuestFileDropView {
        QuestFileDropView(rootView: AnyView(content()))
    }

    func updateNSView(_ view: QuestFileDropView, context: Context) {
        view.rootView = AnyView(content())
        view.canAccept = canAccept
        view.onReceiving = onReceiving
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        view.onError = onError
    }

    static func dismantleNSView(_ view: QuestFileDropView, coordinator: ()) {
        view.cancelPendingDrop()
    }
}

@MainActor
final class QuestFileDropView: NSHostingView<AnyView> {
    var canAccept: () -> Bool = { false }
    var onTargeted: (Bool) -> Void = { _ in }
    var onReceiving: (Bool) -> Void = { _ in }
    var onDrop: ([URL], URL?) -> Bool = { _, _ in false }
    var onError: (String) -> Void = { _ in }

    private struct PendingDrop {
        let id = UUID()
        let directory: URL
        var remaining: Int
        var urls: [URL] = []
    }
    private var pending: PendingDrop?
    private var timeout: DispatchWorkItem?
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        let promisedTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL] + promisedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender.draggingPasteboard) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender.draggingPasteboard) }
    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { operation(for: sender.draggingPasteboard) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { receive(sender.draggingPasteboard) }

    private func operation(for pasteboard: NSPasteboard) -> NSDragOperation {
        let accepted = canAccept() && pending == nil && pasteboard.canReadObject(forClasses: [NSURL.self, NSFilePromiseReceiver.self], options: [.urlReadingFileURLsOnly: true])
        onTargeted(accepted)
        return accepted ? .copy : []
    }

    /// Kept separate from NSDraggingInfo so native pasteboard delivery can be checked offscreen.
    func receive(_ pasteboard: NSPasteboard) -> Bool {
        onTargeted(false)
        guard canAccept(), pending == nil else { return false }
        guard (pasteboard.pasteboardItems?.count ?? 0) <= NewQuestFormModel.maxAttachments else {
            onError("Attach at most \(NewQuestFormModel.maxAttachments) files at a time.")
            return false
        }
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        if receivers.isEmpty {
            guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            return onDrop(urls, nil)
        }
        let count = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
        guard count <= NewQuestFormModel.maxAttachments else {
            onError("Attach at most \(NewQuestFormModel.maxAttachments) files at a time.")
            return false
        }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("quest-attachment-drop-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { onError(error.localizedDescription); return false }
        let drop = PendingDrop(directory: directory, remaining: count)
        pending = drop
        onReceiving(true)
        let expiry = DispatchWorkItem { [weak self] in
            guard let self, self.pending?.id == drop.id else { return }
            self.cancelPendingDrop()
            if self.canAccept() { self.onError("The dropped files did not arrive. Try Choose a File instead.") }
        }
        timeout = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: expiry)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: promiseQueue) { [weak self] url, error in
                DispatchQueue.main.async {
                    self?.receivedPromise(id: drop.id, url: url, error: error)
                }
            }
        }
        return true
    }

    private func receivedPromise(id: UUID, url: URL, error: Error?) {
        guard var drop = pending, drop.id == id else { return }
        guard error == nil, url.resolvingSymlinksInPath().path.hasPrefix(drop.directory.path + "/") else {
            cancelPendingDrop()
            if canAccept() { onError(error?.localizedDescription ?? "The dropped file could not be received.") }
            return
        }
        drop.urls.append(url.resolvingSymlinksInPath())
        drop.remaining -= 1
        pending = drop
        guard drop.remaining == 0 else { return }
        timeout?.cancel()
        timeout = nil
        pending = nil
        onReceiving(false)
        // A modal opened or closed while the source was writing: never hand its files to another surface.
        if !canAccept() || !onDrop(drop.urls, drop.directory) {
            try? FileManager.default.removeItem(at: drop.directory)
        }
    }

    func cancelPendingDrop() {
        timeout?.cancel()
        timeout = nil
        promiseQueue.cancelAllOperations()
        if let directory = pending?.directory {
            try? FileManager.default.removeItem(at: directory)
            onReceiving(false)
        }
        pending = nil
    }
}
