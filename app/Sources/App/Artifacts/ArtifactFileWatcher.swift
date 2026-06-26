import Darwin
import Foundation

final class ArtifactFileWatcher {
    private let debounceInterval: TimeInterval
    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var onChange: (() -> Void)?
    private var debounceWorkItem: DispatchWorkItem?

    init(debounceInterval: TimeInterval = 0.15) {
        self.debounceInterval = debounceInterval
    }

    deinit {
        stop()
    }

    func start(path: String, onChange: @escaping () -> Void) {
        stop()
        watchedPath = path
        self.onChange = onChange
        openSource(path: path)
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
        watchedPath = nil
        onChange = nil
    }

    private func openSource(path: String) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleChange()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    private func scheduleChange() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            onChange?()
            reopenCurrentPath()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func reopenCurrentPath() {
        guard let path = watchedPath else {
            return
        }
        source?.cancel()
        source = nil
        openSource(path: path)
    }
}
