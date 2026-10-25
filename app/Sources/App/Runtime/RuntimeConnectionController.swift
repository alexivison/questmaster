import Foundation
import QuestmasterCore

@MainActor
final class RuntimeConnectionController {
    private let runtimeStore: RuntimeStore
    private let render: () -> Void
    private let connection: DaemonConnection
    private var runtimeClient: UnixSocketServeClient?
    private var pendingCoalescedRender = false
    private var connected = false
    private var incompatible = false

    init(connection: DaemonConnection, runtimeStore: RuntimeStore, render: @escaping () -> Void) {
        self.connection = connection
        self.runtimeStore = runtimeStore
        self.render = render
    }

    func start(onInitialAttemptComplete: @escaping () -> Void) {
        guard runtimeClient == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { [connection, weak self] in
            _ = try? connection.record()
            DispatchQueue.main.async {
                guard let self else { return }
                self.startRuntimeClient()
                onInitialAttemptComplete()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.connected, !self.incompatible else { return }
            self.runtimeStore.apply(.serveUnavailable(DaemonWaitingStatus.message(after: 5)))
            self.scheduleCoalescedRender()
        }
    }

    private func startRuntimeClient() {
        let client = UnixSocketServeClient(connection: connection)
        runtimeClient = client
        client.start(
            onUpdate: { [weak self] update in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if update.observedLabel?.contains("incompatible backend") == true {
                        self.incompatible = true
                    } else if update.observedLabel?.contains("backend") != true {
                        self.incompatible = false
                    }
                    self.runtimeStore.apply(update)
                    self.scheduleCoalescedRender()
                }
            },
            onStatus: { [weak self] status in
                DispatchQueue.main.async {
                    if status == "backend connected" { self?.connected = true }
                    self?.scheduleCoalescedRender()
                }
            }
        )
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
