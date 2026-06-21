import Foundation

public struct QuestDocument: Decodable {
    public var id: String
    public var title: String
    public var status: String
    public var summary: String
    public var date: String
    public var project: String
    public var related: [RelatedLink]
    public var attachments: [QuestAttachmentRef]
    public var gates: [QuestGate]
    public var body: [QuestBlock]
    public var comments: [QuestComment]
    public var runtime: QuestRuntime
    public var commentCount: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case status
        case summary
        case date
        case project
        case related
        case attachments
        case gates
        case body
        case comments
        case runtime
    }

    public init(
        id: String,
        title: String,
        status: String,
        summary: String,
        date: String,
        project: String,
        related: [RelatedLink],
        attachments: [QuestAttachmentRef] = [],
        gates: [QuestGate],
        body: [QuestBlock],
        comments: [QuestComment],
        runtime: QuestRuntime,
        commentCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.date = date
        self.project = project
        self.related = related
        self.attachments = attachments
        self.gates = gates
        self.body = body
        self.comments = comments
        self.runtime = runtime
        self.commentCount = commentCount ?? comments.filter { $0.status != "resolved" }.count
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? id
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "wip"
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        project = try container.decodeIfPresent(String.self, forKey: .project) ?? ""
        related = container.decodeLossyArray(RelatedLink.self, forKey: .related)
        attachments = container.decodeLossyArray(QuestAttachmentRef.self, forKey: .attachments)
        gates = container.decodeLossyArray(QuestGate.self, forKey: .gates)
        body = container.decodeLossyArray(QuestBlock.self, forKey: .body)
        comments = container.decodeLossyArray(QuestComment.self, forKey: .comments)
        runtime = try container.decodeIfPresent(QuestRuntime.self, forKey: .runtime) ?? QuestRuntime()
        commentCount = comments.filter { $0.status != "resolved" }.count
    }
}

public struct QuestRuntime: Decodable {
    public var sessions: [String]
    public var sessionDetails: [QuestAdventurer]
    public var adventurers: [QuestAdventurer]
    public var agent: String
    public var gates: [String: String]
    public var gatesAt: [String: String]
    public var observedAt: String
    public var loop: QuestLoop?

    public init(
        sessions: [String] = [],
        sessionDetails: [QuestAdventurer] = [],
        adventurers: [QuestAdventurer] = [],
        agent: String = "",
        gates: [String: String] = [:],
        gatesAt: [String: String] = [:],
        observedAt: String = "",
        loop: QuestLoop? = nil
    ) {
        self.sessions = sessions
        self.sessionDetails = sessionDetails.isEmpty ? adventurers : sessionDetails
        self.adventurers = adventurers
        self.agent = agent
        self.gates = gates
        self.gatesAt = gatesAt
        self.observedAt = observedAt
        self.loop = loop
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
        case session_details
        case adventurers
        case agent
        case gates
        case gates_at
        case observed_at
        case loop
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let canonicalDetails = try container.decodeIfPresent([QuestAdventurer].self, forKey: .session_details) ?? []
        let legacyAdventurers = try container.decodeIfPresent([QuestAdventurer].self, forKey: .adventurers) ?? []
        sessionDetails = canonicalDetails.isEmpty ? legacyAdventurers : canonicalDetails
        adventurers = sessionDetails
        sessions = try container.decodeIfPresent([String].self, forKey: .sessions) ?? adventurers.map(\.id)
        agent = try container.decodeIfPresent(String.self, forKey: .agent) ?? ""
        gates = try container.decodeIfPresent([String: String].self, forKey: .gates) ?? [:]
        gatesAt = try container.decodeIfPresent([String: String].self, forKey: .gates_at) ?? [:]
        observedAt = try container.decodeIfPresent(String.self, forKey: .observed_at) ?? ""
        loop = try container.decodeIfPresent(QuestLoop.self, forKey: .loop)
    }
}

public struct QuestPayload: Decodable {
    public var quest: QuestDocument
    public var observedLabel: String

    private enum CodingKeys: String, CodingKey {
        case quest
        case runtime
        case observed_at
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quest = try container.decode(QuestDocument.self, forKey: .quest)
        if let runtime = try container.decodeIfPresent(QuestRuntime.self, forKey: .runtime) {
            quest.runtime = runtime
        }
        observedLabel = try container.decodeIfPresent(String.self, forKey: .observed_at) ?? ""
    }
}

public struct QuestAdventurer: Decodable {
    public var id: String
    public var agent: String
    public var state: String
    public var since: String
    public var loop: QuestLoop?

    public init(id: String, agent: String, state: String, since: String = "", loop: QuestLoop? = nil) {
        self.id = id
        self.agent = agent
        self.state = state
        self.since = since
        self.loop = loop
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case agent
        case state
        case since
        case loop
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            agent: try container.decodeIfPresent(String.self, forKey: .agent) ?? "",
            state: try container.decodeIfPresent(String.self, forKey: .state) ?? "",
            since: try container.decodeIfPresent(String.self, forKey: .since) ?? "",
            loop: try container.decodeIfPresent(QuestLoop.self, forKey: .loop)
        )
    }
}

public struct QuestLoop: Decodable {
    public var sessionID: String
    public var iterations: Int
    public var lastVerdict: String
    public var phase: String

    public init(sessionID: String = "", iterations: Int = 0, lastVerdict: String = "", phase: String = "") {
        self.sessionID = sessionID
        self.iterations = iterations
        self.lastVerdict = lastVerdict
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case session_id
        case iterations
        case last_verdict
        case phase
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(String.self, forKey: .session_id) ?? ""
        iterations = try container.decodeIfPresent(Int.self, forKey: .iterations) ?? 0
        lastVerdict = try container.decodeIfPresent(String.self, forKey: .last_verdict) ?? ""
        phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? ""
    }
}

public struct QuestGate: Decodable {
    public var name: String
    public var type: String
    public var check: String
    public var before: String
    public var checked: Bool

    public init(name: String, type: String, check: String = "", before: String = "", checked: Bool = false) {
        self.name = name
        self.type = type
        self.check = check
        self.before = before
        self.checked = checked
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case check
        case before
        case checked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            type: try container.decodeIfPresent(String.self, forKey: .type) ?? "",
            check: try container.decodeIfPresent(String.self, forKey: .check) ?? "",
            before: try container.decodeIfPresent(String.self, forKey: .before) ?? "",
            checked: try container.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        )
    }
}

public struct QuestBlock: Decodable {
    public var type: String
    public var id: String
    public var level: Int
    public var text: String
    public var ordered: Bool
    public var items: [String]
    public var lang: String
    public var format: String
    public var fallback: String
    public var content: String

    public init(
        type: String,
        id: String = "",
        level: Int = 0,
        text: String = "",
        ordered: Bool = false,
        items: [String] = [],
        lang: String = "",
        format: String = "",
        fallback: String = "",
        content: String = ""
    ) {
        self.type = type
        self.id = id
        self.level = level
        self.text = text
        self.ordered = ordered
        self.items = items
        self.lang = lang
        self.format = format
        self.fallback = fallback
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case level
        case text
        case ordered
        case items
        case lang
        case format
        case fallback
        case content
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decodeIfPresent(String.self, forKey: .type) ?? "",
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            level: try container.decodeIfPresent(Int.self, forKey: .level) ?? 0,
            text: try container.decodeIfPresent(String.self, forKey: .text) ?? "",
            ordered: try container.decodeIfPresent(Bool.self, forKey: .ordered) ?? false,
            items: try container.decodeIfPresent([String].self, forKey: .items) ?? [],
            lang: try container.decodeIfPresent(String.self, forKey: .lang) ?? "",
            format: try container.decodeIfPresent(String.self, forKey: .format) ?? "",
            fallback: try container.decodeIfPresent(String.self, forKey: .fallback) ?? "",
            content: try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        )
    }
}

public struct RelatedLink: Decodable {
    public var id: String
    public var type: String
    public var title: String
    public var url: String

    public init(id: String = "", type: String = "", title: String, url: String = "") {
        self.id = id
        self.type = type
        self.title = title
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let title = try? container.decode(String.self) {
            self.init(title: title)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedURL = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            type: try container.decodeIfPresent(String.self, forKey: .type) ?? "",
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? decodedURL,
            url: decodedURL
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case url
    }
}

public struct QuestAttachmentRef: Decodable {
    public var itemID: String
    public var type: String
    public var title: String

    public var linkURL: URL? {
        URL(string: "questmaster-item://\(itemID)")
    }

    public init(itemID: String, type: String, title: String) {
        self.itemID = itemID
        self.type = type
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case item_id
        case type
        case title
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decodeIfPresent(String.self, forKey: .item_id) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? itemID
    }
}

public struct QuestComment: Decodable {
    public var id: String
    public var anchor: CommentAnchor
    public var status: String
    public var author: String
    public var body: String
    public var createdAt: String

    public init(id: String, anchor: CommentAnchor, status: String, author: String, body: String, createdAt: String) {
        self.id = id
        self.anchor = anchor
        self.status = status
        self.author = author
        self.body = body
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case anchor
        case status
        case author
        case body
        case created_at
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        anchor = try container.decodeIfPresent(CommentAnchor.self, forKey: .anchor) ?? CommentAnchor()
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "open"
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .created_at) ?? ""
    }
}

public struct CommentAnchor: Decodable {
    public var kind: String
    public var id: String
    public var item: Int?

    public init(kind: String = "", id: String = "", item: Int? = nil) {
        self.kind = kind
        self.id = id
        self.item = item
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
        case item
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decodeIfPresent(String.self, forKey: .kind) ?? "",
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? "",
            item: try container.decodeIfPresent(Int.self, forKey: .item)
        )
    }
}
