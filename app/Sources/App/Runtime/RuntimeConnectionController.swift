import Foundation
import QuestmasterCore

@MainActor
final class RuntimeConnectionController {
    private let runtimeStore: RuntimeStore
    private let render: () -> Void
    private let connection: DaemonConnection
    private var runtimeClient: UnixSocketServeClient?
    private var pendingCoalescedRender = false

    init(connection: DaemonConnection, runtimeStore: RuntimeStore, render: @escaping () -> Void) {
        self.connection = connection
        self.runtimeStore = runtimeStore
        self.render = render
    }

    func start(onInitialAttemptComplete: @escaping () -> Void) {
        guard runtimeClient == nil else { return }
        // Connecting starts here, with the daemon record, before the client's own loop does.
        runtimeStore.apply(RuntimeUpdate(connection: .connecting))
        scheduleCoalescedRender()
        DispatchQueue.global(qos: .userInitiated).async { [connection, weak self] in
            _ = try? connection.record()
            DispatchQueue.main.async {
                guard let self else { return }
                self.startRuntimeClient()
                onInitialAttemptComplete()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ConnectionState.waitingWindow) { [weak self] in
            guard let self, self.runtimeStore.snapshot.connection == .connecting else { return }
            self.runtimeStore.apply(RuntimeUpdate(connection: .unavailable))
            self.scheduleCoalescedRender()
        }
    }

    private func startRuntimeClient() {
        let client = UnixSocketServeClient(connection: connection)
        runtimeClient = client
        client.start(onUpdate: { [weak self] update in
            DispatchQueue.main.async {
                guard let self else { return }
                self.runtimeStore.apply(update)
                self.scheduleCoalescedRender()
            }
        })
    }

    func stop() { runtimeClient?.stop() }

    private func scheduleCoalescedRender() {
        guard !pendingCoalescedRender else { return }
        pendingCoalescedRender = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingCoalescedRender = false
            self.render()
        }
    }
}
