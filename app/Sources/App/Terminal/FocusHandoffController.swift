import QuestmasterCore

@MainActor
final class FocusHandoffController {
    private let socketPath: String
    private let onDirection: (NavigationDirection) -> String?
    private var server: FocusHandoffServer?

    init(socketPath: String, onDirection: @escaping (NavigationDirection) -> String?) {
        self.socketPath = socketPath
        self.onDirection = onDirection
    }

    func start() {
        guard server == nil else {
            return
        }
        let server = FocusHandoffServer(socketPath: socketPath, handler: onDirection)
        self.server = server
        server.start()
    }

    func stop() {
        server?.stop()
        server = nil
    }
}
