import Foundation
import QuestmasterCore

/// Runs the pulls `PullRequestStore` asks for. The store decides when to pull; this only carries a request to the
/// daemon socket and hands the response back, chaining the follow-up it returns.
@MainActor
final class PullRequestController {
    private let store: PullRequestStore
    private let client: () -> UnixSocketMutationClient?
    private var settleTask: Task<Void, Never>?

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

    /// Asks the daemon to re-read the session's pull requests and waits for its reply, which ends the refresh the store is
    /// showing. Whatever changed comes back through `sync`.
    func refresh(_ request: PullRequestRefreshRequest) {
        // Arms the cap: with no reply the store ends the refresh itself.
        settle(after: store.settleRefresh())
        guard let client = client() else {
            finish(request, failed: true)
            return
        }
        client.refreshPullRequests(request) { [weak self] result in
            let failed: Bool
            if case .failure = result {
                failed = true
            } else {
                failed = false
            }
            Task { @MainActor in
                self?.finish(request, failed: failed)
            }
        }
    }

    private func finish(_ request: PullRequestRefreshRequest, failed: Bool) {
        settle(after: store.finishRefresh(request, failed: failed))
    }

    /// Asks the store to settle its refresh once `delay` has passed (nil: nothing left to wait for), and again if it still
    /// has time to run. One timer at a time.
    private func settle(after delay: TimeInterval?) {
        settleTask?.cancel()
        guard let delay else {
            settleTask = nil
            return
        }
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else {
                return
            }
            self.settle(after: self.store.settleRefresh())
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
