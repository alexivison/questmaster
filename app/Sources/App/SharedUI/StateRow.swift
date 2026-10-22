import AppKit
import QuestmasterCore
import SwiftUI

/// The pointer (AGENTS.md, "Interaction states"): it shows the hover look on the row under it, the keys move the
/// cursor, and a click acts. Only in the tracker, while it has the keys, does hover move the cursor; there only real
/// pointer motion counts, so a list that scrolls under a still pointer after a key press keeps its cursor, and the
/// list doesn't scroll to a cursor the pointer moved (`cursor`).
@MainActor
enum PointerHighlight {
    private static var movedAt = Date.distantPast
    /// A hover callback this soon after a pointer move is that move's.
    private static let moveWindow: TimeInterval = 0.1
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

    /// The cursor change the pointer made in the tracker, which its list doesn't scroll to.
    static var cursor = PointerCursor()
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

    /// A list row in its state look, with the hover look (a `line` outline) while the pointer is over a resting row.
    /// The pointer moves no cursor here: a click acts.
    func stateRow(_ look: RowLook, cornerRadius: CGFloat = 0) -> some View {
        modifier(StateRowModifier(look: look, cornerRadius: cornerRadius))
    }
}

private struct StateRowModifier: ViewModifier {
    let look: RowLook
    let cornerRadius: CGFloat
    @State private var pointerOver = false

    func body(content: Content) -> some View {
        content
            .background {
                let shown = look.underPointer(pointerOver)
                if let fill = shown.fill {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(fill.color.swiftUI)
                }
                if let outline = shown.outline {
                    RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(outline.color.swiftUI, lineWidth: Token.Size.divider)
                }
            }
            .contentShape(Rectangle())
            .onHover { pointerOver = $0 }
    }
}
