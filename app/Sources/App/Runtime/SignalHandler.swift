import Darwin
import Dispatch

@MainActor
final class SignalHandler {
    private var sources: [DispatchSourceSignal] = []

    func install(_ handler: @escaping () -> Void) {
        guard sources.isEmpty else {
            return
        }

        for value in [SIGINT, SIGTERM] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.removeAll()
    }
}
