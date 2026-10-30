import Foundation

/// A tracker event the class avatar answers: a master spawned a worker, sent a worker a message, or a worker reported to
/// its master.
public enum TrackerAvatarEvent: Equatable {
    case spawned(worker: String)
    case messaged(worker: String)
    case reported(worker: String)
}

/// Reads the avatar's events from consecutive tracker payloads, so they arrive whether or not the Worker Log is open.
/// The first payload, an attach and a switch to another session are a baseline: they show no events, so a session's
/// existing workers and exchanges don't replay.
public struct TrackerAvatarEventDetector {
    /// The `last_exchange` kinds the tracker writes: a message from a master to a worker, and a worker's report.
    private enum ExchangeKind {
        static let instructions = "instructions"
        static let report = "report"
    }

    private let catalog: TrackerAvatarCatalog
    private var previousRows: [String: TrackerSession]?
    private var previousAttachedID: String?

    public init(catalog: TrackerAvatarCatalog) {
        self.catalog = catalog
    }

    /// The events between the last payload and `rows`, for the attached session when it shows an avatar.
    public mutating func observe(_ rows: [TrackerSession], attachedID: String?) -> [TrackerAvatarEvent] {
        let before = previousRows
        let sameAttachment = attachedID == previousAttachedID
        previousRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        previousAttachedID = attachedID
        guard let before, sameAttachment, let attachedID,
              let master = rows.first(where: { $0.id == attachedID }),
              catalog.animation(for: master) != nil else {
            return []
        }
        return rows.filter { $0.parentID == attachedID }.flatMap { events(for: $0, before: before) }
    }

    private func events(for worker: TrackerSession, before: [String: TrackerSession]) -> [TrackerAvatarEvent] {
        guard let previous = before[worker.id] else {
            return [.spawned(worker: worker.id)]
        }
        guard let exchange = worker.lastExchange, exchange != previous.lastExchange else {
            return []
        }
        switch exchange.kind {
        case ExchangeKind.instructions: return [.messaged(worker: worker.id)]
        case ExchangeKind.report: return [.reported(worker: worker.id)]
        default: return []
        }
    }
}
