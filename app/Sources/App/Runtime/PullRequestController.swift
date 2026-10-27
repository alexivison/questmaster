import Foundation
import QuestmasterCore

/// Runs the pulls `PullRequestStore` asks for. The store decides when to pull; this only carries a request to the
/// daemon socket and hands the response back, chaining the follow-up it returns.
@MainActor
final class PullRequestController {
    private let store: PullRequestStore
    private let client: () -> UnixSocketMutationClient?

    init(store: PullRequestStore, client: @escaping () -> UnixSocketMutationClient?) {
        self.store = store
        self.client = client
    }

    func sync(selectedSessionID: String?, sessions: [TrackerSession], isVisible: Bool) {
        guard let request = store.sync(selectedSessionID: selectedSessionID, sessions: sessions, isVisible: isVisible) else {
            return
        }
        pull(request)
    }

    /// Asks the daemon to re-read the session's pull requests. Whatever changed comes back through `sync`.
    func refresh(_ request: PullRequestRefreshRequest) {
        guard let client = client() else {
            store.failRefresh()
            return
        }
        client.refreshPullRequests(request) { [weak self] result in
            guard case .failure = result else {
                return
            }
            Task { @MainActor in
                self?.store.failRefresh()
            }
        }
    }

    private func pull(_ request: PullRequestsRequest) {
        guard let client = client() else {
            chain(store.fail(error: ServeClientError.connect("no daemon client"), for: request))
            return
        }
        client.fetchPullRequests(request) { [weak self] result in
            Task { @MainActor in
                self?.finish(request, result)
            }
        }
    }

    private func finish(_ request: PullRequestsRequest, _ result: Result<[PullRequestRow], Error>) {
        switch result {
        case .success(let rows):
            chain(store.apply(response: rows, for: request))
        case .failure(let error):
            chain(store.fail(error: error, for: request))
        }
    }

    private func chain(_ followUp: PullRequestsRequest?) {
        guard let followUp else {
            return
        }
        pull(followUp)
    }
}
