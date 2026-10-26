import Foundation

/// A master session's display class. The ids are the backend's (`internal/state/session_class.go`), in its order,
/// which is also the order the class cycles in.
public enum SessionClass: String, CaseIterable, Equatable, Sendable {
    case paladin
    case wizard
    case druid
    case barbarian
    case rogue
    case cleric
    case bard

    /// New Session's default: no class is sent, and the backend picks one.
    public static let randomLabel = "Random"

    public init?(id: String) {
        self.init(rawValue: id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    public var displayName: String {
        rawValue.capitalized
    }

    /// The class after this one, wrapping to the first.
    public var next: SessionClass {
        let all = Self.allCases
        return all[((all.firstIndex(of: self) ?? 0) + 1) % all.count]
    }

    /// New Session's cycle, with Random (nil) as the slot after the last class: Random, paladin, …, bard, Random.
    public static func next(after choice: SessionClass?) -> SessionClass? {
        guard let choice else {
            return allCases.first
        }
        return choice == allCases.last ? nil : choice.next
    }
}

/// The portrait a disc draws, named by its bundled image: a master's class portrait (nil is the "Random" silhouette),
/// or the familiar a worker shows for its master's class.
public enum SessionPortrait: Equatable, Sendable {
    case master(SessionClass?)
    case familiar(SessionClass)

    /// The image's name in the app bundle. SwiftPM flattens the resource folder, so the kinds carry their own prefix.
    public var resourceName: String {
        switch self {
        case .master(let sessionClass?):
            return "class-\(sessionClass.rawValue)"
        case .master(nil):
            return "random"
        case .familiar(let sessionClass):
            return "familiar-\(sessionClass.rawValue)"
        }
    }

    /// The portrait a tracker row draws: a master's class, a worker's familiar. A shell, and a row without a known
    /// class, have none, and show their agent's logo on the disc instead.
    public init?(session: TrackerSession) {
        guard let sessionClass = SessionClass(id: session.sessionClass) else {
            return nil
        }
        switch SessionRoleKind(role: session.role) {
        case .master:
            self = .master(sessionClass)
        case .worker:
            self = .familiar(sessionClass)
        case .shell, .tmux, .orphan:
            return nil
        }
    }
}

/// ⌃e in the title field cycles the class, as it does the effort in the model field (`NewSessionEffortKey`). It takes
/// over the field's move-to-end-of-line; End and ⌘→ still do that.
public enum SessionClassKey {
    public static func cycles(keyCode: UInt16, command: Bool, control: Bool, option: Bool, titleFocused: Bool) -> Bool {
        titleFocused && control && !command && !option && Keymap.NewSession.cycleClass.matches(keyCode)
    }
}

/// The portrait row of an Edit Session sheet: a master's class, which cycles (nil while the master has none yet, shown as
/// Random); a worker's familiar, which only shows; or nothing, for a shell, a tmux or orphan row, and a worker whose
/// master's class is unknown. Whether a row is a master comes from its role, never from its class, so a master the
/// backfill hasn't reached can still be given one.
public enum EditSessionPortrait: Equatable {
    case choosing(SessionClass?)
    case familiar(SessionClass)
    case none

    public init(session: TrackerSession) {
        let sessionClass = SessionClass(id: session.sessionClass)
        switch SessionRoleKind(role: session.role) {
        case .master:
            self = .choosing(sessionClass)
        case .worker:
            self = sessionClass.map(EditSessionPortrait.familiar) ?? .none
        case .shell, .tmux, .orphan:
            self = .none
        }
    }

    public var portrait: SessionPortrait? {
        switch self {
        case .choosing(let sessionClass):
            return .master(sessionClass)
        case .familiar(let sessionClass):
            return .familiar(sessionClass)
        case .none:
            return nil
        }
    }

    /// The title field's trailing segment: the class's name, or "Random" for a master with none yet. A familiar is
    /// read-only and shows none.
    public var label: String? {
        guard case .choosing(let sessionClass) = self else {
            return nil
        }
        return sessionClass?.displayName ?? SessionClass.randomLabel
    }

    /// What the portrait is called to assistive technology; nil without a portrait.
    public var accessibilityLabel: String? {
        switch self {
        case .choosing:
            return label.map { "Class \($0)" }
        case .familiar(let sessionClass):
            return "\(sessionClass.displayName) familiar"
        case .none:
            return nil
        }
    }

    public var isEditable: Bool {
        label != nil
    }

    /// ⌃e and a click on the portrait: the next class, wrapping. An edit has no Random to return to, so a master with
    /// none yet starts at the first class. Nothing for a familiar or no portrait.
    public mutating func cycle() {
        guard case .choosing(let sessionClass) = self else {
            return
        }
        self = .choosing(sessionClass?.next ?? SessionClass.allCases[0])
    }

    /// What saving sends for the class: a reclass, only when the class changed from `initial`.
    public func reclassRequest(sessionID: String, since initial: EditSessionPortrait) throws -> ServeMutationRequest? {
        guard case .choosing(let sessionClass?) = self, self != initial else {
            return nil
        }
        return try ServeMutationRequests.reclass(sessionID: sessionID, to: sessionClass)
    }
}
