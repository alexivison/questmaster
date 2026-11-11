import Foundation
import QuestmasterCore

@MainActor
final class AsyncTerminalAttach<Output> {
    private let queue = DispatchQueue(label: "questmaster.terminal.attach", qos: .userInitiated)
    private let gate = AttachRequestGate()

    init() {}

    func request(
        work: @escaping () -> Result<Output, Error>,
        completion: @escaping (Result<Output, Error>) -> Void
    ) {
        let request = gate.request()
        let gate = self.gate
        queue.async {
            guard gate.accepts(request) else { return }
            let result = work()
            DispatchQueue.main.async {
                guard gate.accepts(request) else { return }
                completion(result)
            }
        }
    }

    func stop() { gate.stop() }
    func detach() { gate.detach() }
}

private final class AttachRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = AttachGeneration()

    func request() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation.request()
    }

    func accepts(_ request: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation.accepts(request)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        generation.stop()
    }

    func detach() {
        lock.lock(); defer { lock.unlock() }
        generation.detach()
    }
}
