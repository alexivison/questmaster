import Foundation
import QuestmasterCore

@MainActor
final class RuntimeConnectionController {
    private let config: LaunchConfiguration
    private let runtimeStore: RuntimeStore
    private let render: () -> Void

    private var serveProcess: ServeProcess?
    private var runtimeClient: UnixSocketServeClient?
    private var didStartRuntimeClient = false
    private var pendingCoalescedRender = false

    init(config: LaunchConfiguration, runtimeStore: RuntimeStore, render: @escaping () -> Void) {
        self.config = config
        self.runtimeStore = runtimeStore
        self.render = render
    }

    func start(launchSessionID: String?) {
        guard config.launchServe else {
            startRuntimeClient()
            return
        }

        let process = ServeProcess(
            socketPath: config.serveSocket,
            backend: config.backend,
            sessionID: launchSessionID
        )
        serveProcess = process
        process.start(
            onStatus: { [weak self] status in
                DispatchQueue.main.async {
                    self?.applyServeProcessStatus(status)
                }
            },
            onReady: { [weak self] in
                DispatchQueue.main.async {
                    self?.startRuntimeClient()
                }
            }
        )
    }

    func stop() {
        runtimeClient?.stop()
        serveProcess?.stop()
    }

    // Coalesce serve-driven renders: multiple update/status callbacks arriving in
    // the same runloop turn produce a single render() on the main thread.
    private func scheduleCoalescedRender() {
        guard !pendingCoalescedRender else {
            return
        }
        pendingCoalescedRender = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.pendingCoalescedRender = false
            self.render()
        }
    }

    private func applyServeProcessStatus(_ status: String) {
        if let serviceMessage = Self.serviceStateMessage(forServeProcessStatus: status) {
            runtimeStore.apply(.serveUnavailable(serviceMessage))
        }
        scheduleCoalescedRender()
    }

    private func startRuntimeClient() {
        guard !didStartRuntimeClient else {
            return
        }
        didStartRuntimeClient = true

        let client = UnixSocketServeClient(socketPath: config.serveSocket)
        runtimeClient = client
        client.start(
            onUpdate: { [weak self] update in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    self.runtimeStore.apply(update)
                    self.scheduleCoalescedRender()
                }
            },
            onStatus: { [weak self] _ in
                DispatchQueue.main.async {
                    self?.scheduleCoalescedRender()
                }
            }
        )
    }

    static func serviceStateMessage(forServeProcessStatus status: String) -> String? {
        let lowercased = status.lowercased()
        if lowercased.contains("starting") {
            return "connecting to serve..."
        }
        if lowercased.contains("not found")
            || lowercased.contains("failed")
            || lowercased.contains("restart limit")
            || lowercased.contains("did not become ready")
            || lowercased.contains("exited before")
            || lowercased.contains("serve exited") {
            if lowercased.contains("restart limit") {
                return "serve stopped - restart required"
            }
            return "serve not connected - retrying"
        }
        return nil
    }
}
