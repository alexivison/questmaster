import Foundation

public struct PullRequestsResponse: Decodable {
    public let data: [PullRequestRow]
}

public struct PullRequestRow: Decodable, Equatable {
    public struct Watcher: Decodable, Equatable {
        public let sessionID: String
        public let addedAt: String

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id", addedAt = "added_at"
        }
    }

    public let key: String
    public let host: String
    public let owner: String
    public let repo: String
    public let number: Int
    public let watchers: [Watcher]
    public let status: PullRequestStatus?
}

public struct PullRequestStatus: Decodable, Equatable {
    public let title: String?
    public let url: String?
    public let state: PullRequestState?
    public let draft: Bool
    public let headSHA: String?
    public let updatedAt: String?
    public let additions: Int
    public let deletions: Int
    public let comments: Int
    public let review: PullRequestReview?
    public let ci: PullRequestCI?
    public let fetchedAt: String?
    public let inaccessibleReason: PullRequestInaccessibleReason?
    public let stale: Bool

    private enum CodingKeys: String, CodingKey {
        case title, url, state, draft, additions, deletions, comments, review, ci, stale
        case headSHA = "head_sha", updatedAt = "updated_at", fetchedAt = "fetched_at"
        case inaccessibleReason = "inaccessible_reason"
    }
}

public enum PullRequestState: String, Decodable {
    case open, closed, merged, unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum PullRequestReview: String, Decodable {
    case approved, changesRequested = "changes_requested", reviewRequired = "review_required", none, unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum PullRequestCI: String, Decodable {
    case success, failure, pending, none, unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum PullRequestInaccessibleReason: String, Decodable {
    case notFound = "not_found", forbidden, saml, unknown

    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

public enum ReviewLook: Equatable {
    case approved, changesRequested, reviewRequired, none
}

public enum CILook: Equatable {
    case success, failure, pending, none
}

public enum PullRequestRowLook: Equatable {
    case normal, stale, inaccessible
}

/// The git state icon: a draft is an open pull request marked as one. Unknown also covers an inaccessible row.
public enum PullRequestGitState: Equatable {
    case open, draft, merged, closed, unknown
}

/// The worker a master's row is tagged with: its title, and its agent for the logo.
public struct PullRequestWatcherTag: Equatable {
    public let title: String
    public let agent: String

    public init(title: String, agent: String) {
        self.title = title
        self.agent = agent
    }
}

/// A row's text and semantic looks; the App target supplies icons and colours.
public struct PullRequestDisplayRow: Equatable {
    public let pullRequest: PullRequestRow
    public let watcherTags: [PullRequestWatcherTag]

    public var numberLabel: String { "#\(pullRequest.number)" }
    public var repoLabel: String {
        let path = "\(pullRequest.owner)/\(pullRequest.repo)"
        return pullRequest.host == "github.com" ? path : "\(pullRequest.host)/\(path)"
    }
    public var title: String {
        let value = pullRequest.status?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? pullRequest.key : value
    }
    public var additionsLabel: String? {
        accessibleStatus.map { "+" + Self.format($0.additions) }
    }
    public var deletionsLabel: String? {
        accessibleStatus.map { "−" + Self.format($0.deletions) }
    }
    public var changesLabel: String? {
        guard let additions = additionsLabel, let deletions = deletionsLabel else { return nil }
        return "\(additions) \(deletions)"
    }
    public var commentsLabel: String? {
        accessibleStatus.map { Self.format($0.comments) }
    }
    public var inaccessibleLabel: String? {
        switch pullRequest.status?.inaccessibleReason {
        case .notFound: return "Not found"
        case .forbidden: return "No access"
        case .saml: return "SSO required"
        case .unknown: return "Unavailable"
        case nil: return nil
        }
    }
    public var gitState: PullRequestGitState {
        guard let status = accessibleStatus else { return .unknown }
        switch status.state {
        case .open: return status.draft ? .draft : .open
        case .merged: return .merged
        case .closed: return .closed
        case .unknown, nil: return .unknown
        }
    }
    /// The pull request's page: GitHub's own link, or the one its ref implies while no status has loaded.
    public var url: URL? {
        if let raw = pullRequest.status?.url, let url = Self.webURL(raw) { return url }
        return Self.webURL("https://\(pullRequest.host)/\(pullRequest.owner)/\(pullRequest.repo)/pull/\(pullRequest.number)")
    }
    public var reviewLook: ReviewLook {
        switch pullRequest.status?.review {
        case .approved: return .approved
        case .changesRequested: return .changesRequested
        case .reviewRequired: return .reviewRequired
        case .some(.none), .unknown, nil: return .none
        }
    }
    public var ciLook: CILook {
        switch pullRequest.status?.ci {
        case .success: return .success
        case .failure: return .failure
        case .pending: return .pending
        case .some(.none), .unknown, nil: return .none
        }
    }
    public var rowLook: PullRequestRowLook {
        if pullRequest.status?.inaccessibleReason != nil { return .inaccessible }
        return pullRequest.status?.stale == true ? .stale : .normal
    }

    /// The row's look: the cursor's or the resting look, dimmed while stale and warned when inaccessible.
    public func look(highlighted: Bool, areaFocused: Bool) -> RowLook {
        let base = RowLook.pick(highlighted: highlighted, areaFocused: areaFocused)
        switch rowLook {
        case .normal: return base
        case .stale: return base.dimmed
        case .inaccessible: return base.dimmed.warned
        }
    }

    private var accessibleStatus: PullRequestStatus? {
        guard let status = pullRequest.status, status.inaccessibleReason == nil else { return nil }
        return status
    }

    private static func format(_ count: Int) -> String {
        count.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    private static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.host != nil, ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }

    public static func make(
        from rows: [PullRequestRow], selectedSessionID: String?, sessions: [TrackerSession]
    ) -> [Self] {
        let selected = sessions.first { $0.id == selectedSessionID }
        let workers = Dictionary(sessions.filter { $0.parentID == selectedSessionID }.map { session in
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (session.id, PullRequestWatcherTag(title: title.isEmpty ? session.id : title, agent: session.agent))
        }, uniquingKeysWith: { _, latest in latest })
        return rows.map { row in
            let tags = selected?.role == "master"
                ? row.watchers.compactMap { workers[$0.sessionID] }
                : []
            return Self(pullRequest: row, watcherTags: tags)
        }.sorted { lhs, rhs in
            let left = lhs.pullRequest
            let right = rhs.pullRequest
            let leftGroup = sortGroup(left)
            let rightGroup = sortGroup(right)
            if leftGroup != rightGroup { return leftGroup < rightGroup }
            let leftDate = sortDate(left.status?.updatedAt)
            let rightDate = sortDate(right.status?.updatedAt)
            if leftDate != rightDate { return leftDate > rightDate }
            return left.key < right.key
        }
    }

    private static func sortGroup(_ row: PullRequestRow) -> Int {
        guard let status = row.status else { return 4 }
        guard status.inaccessibleReason == nil else { return 3 }
        switch status.state {
        case .open: return 0
        case .closed: return 1
        case .merged: return 2
        case .unknown, nil: return 3
        }
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainDateFormatter = ISO8601DateFormatter()

    private static func sortDate(_ raw: String?) -> Date {
        guard let raw else { return .distantPast }
        return fractionalDateFormatter.date(from: raw) ?? plainDateFormatter.date(from: raw) ?? .distantPast
    }
}
