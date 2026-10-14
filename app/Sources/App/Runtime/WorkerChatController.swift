import Foundation
import QuestmasterCore

/// Runs the pulls `WorkerChatStore` asks for. The store decides when to pull; this only carries
/// a request to the serve socket and hands the response back, chaining the follow-up it returns.
@MainActor
final class WorkerChatController {
    private let store: WorkerChatStore
    private let feedClient: () -> UnixSocketMutationClient?

    init(store: WorkerChatStore, feedClient: @escaping () -> UnixSocketMutationClient?) {
        self.store = store
        self.feedClient = feedClient
    }

    func sync(selectedSessionID: String?, sessions: [TrackerSession], isVisible: Bool) {
        guard let request = store.sync(selectedSessionID: selectedSessionID, sessions: sessions, isVisible: isVisible) else {
            return
        }
        pull(request)
    }

    private func pull(_ request: WorkerFeedRequest) {
        guard let client = feedClient() else {
            store.fail(request)
            return
        }
        client.fetchWorkerFeed(request) { [weak self] result in
            Task { @MainActor in
                self?.finish(request, result)
            }
        }
    }

    private func finish(_ request: WorkerFeedRequest, _ result: Result<WorkerFeedPayload, Error>) {
        switch result {
        case .success(let payload):
            if let followUp = store.receive(payload, for: request) {
                pull(followUp)
            }
        case .failure:
            store.fail(request)
        }
    }
}
