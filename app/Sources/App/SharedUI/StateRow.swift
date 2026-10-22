import AppKit
import QuestmasterCore
import SwiftUI

/// The one highlight (AGENTS.md, "Interaction states"): the pointer moving onto a row moves the keyboard cursor
/// there, and the arrow keys or j/k continue from it. Only real pointer motion counts, so a list that scrolls under a
/// still pointer after a key press keeps its cursor, and a cursor the pointer just moved doesn't scroll its list.
@MainActor
enum PointerHighlight {
    private static var movedAt = Date.distantPast
    /// A hover callback this soon after a pointer move is that move's.
    private static let moveWindow: TimeInterval = 0.1
    /// A cursor change this soon after a pointer move came from the pointer, so its list stays put.
    private static let scrollHoldWindow: TimeInterval = 0.3
    private static let monitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
        MainActor.assumeIsolated { movedAt = Date() }
        return event
    }

    static func install() {
        _ = monitor
    }

    fileprivate static var pointerIsMoving: Bool {
        install()
        return Date().timeIntervalSince(movedAt) < moveWindow
    }

    /// Whether the cursor just moved because the pointer did: such a move doesn't scroll its list.
    static var pointerJustMoved: Bool {
        Date().timeIntervalSince(movedAt) < scrollHoldWindow
    }
}

extension View {
    /// Calls `highlight` as the pointer moves over this view.
    func highlightOnHover(_ highlight: @escaping () -> Void) -> some View {
        onContinuousHover { phase in
            guard case .active = phase, PointerHighlight.pointerIsMoving else {
                return
            }
            highlight()
        }
    }

    /// A list row in its state look: the look's fill behind it, and the pointer moving onto a row that isn't
    /// highlighted yet (it has no fill) highlights it.
    func stateRow(_ look: RowLook, cornerRadius: CGFloat = 0, onHighlight: @escaping () -> Void) -> some View {
        background {
            if let fill = look.fill {
                RoundedRectangle(cornerRadius: cornerRadius).fill(fill.color.swiftUI)
            }
        }
        .contentShape(Rectangle())
        .highlightOnHover {
            if look.fill == nil {
                onHighlight()
            }
        }
    }
}
