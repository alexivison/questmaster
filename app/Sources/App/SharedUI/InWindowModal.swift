import AppKit
import Combine
import QuestmasterCore
import SwiftUI

/// The app's modals, drawn inside the main window instead of as system sheets. SwiftUI's `.sheet` on macOS
/// is a titled sheet window whose frame puts a visual-effect panel, a rounded corner mask and a light edge
/// behind the content, and none of that can be cleared reliably, so the scooped corners would show it.
/// Every modal, the Quest Log included, is pushed here and drawn by `InWindowModalHost`, newest on top; only the
/// top open modal takes keys (`SheetKeyEventMonitor`), so Esc closes modals in stack order.
@MainActor
final class InWindowModalStack: ObservableObject {
    // ponytail: one stack for the app's one main window; give each window its own if the app ever opens more.
    static let shared = InWindowModalStack()

    struct Entry: Identifiable {
        let id: AnyHashable
        var kind: ModalKind = .other
        let view: AnyView
        /// Dismissed and fading out: still drawn, no longer interactive, removed when the fade ends.
        var closing = false
    }

    /// Every drawn modal, the closing ones included.
    @Published private(set) var entries: [Entry] = []

    /// No modal is open (closing ones don't count).
    var isEmpty: Bool { !entries.contains { !$0.closing } }

    /// The newest modal still open: the one that takes the keys.
    var top: Entry? { entries.last { !$0.closing } }

    /// Whether the modal `id` takes the keys; nil is a view outside the stack, which always does.
    func isTop(_ id: AnyHashable?) -> Bool {
        id == nil || top?.id == id
    }

    /// How a global modal command (a shortcut, menu or the action bar) lands on this stack.
    func route(_ command: GlobalModalCommand) -> ModalCommandRoute {
        ModalCommandRouting.route(command, top: top?.kind)
    }

    func present(id: AnyHashable, kind: ModalKind = .other, _ view: AnyView) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, kind: kind, view: view))
    }

    func dismiss(id: AnyHashable) {
        guard let index = entries.firstIndex(where: { $0.id == id && !$0.closing }) else {
            return
        }
        entries[index].closing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ModalFade.fadeOut) { [weak self] in
            self?.entries.removeAll { $0.id == id && $0.closing }
        }
    }
}

private struct InWindowModalStackKey: EnvironmentKey {
    @MainActor static var defaultValue: InWindowModalStack { .shared }
}

private struct InWindowModalEntryIDKey: EnvironmentKey {
    static let defaultValue: AnyHashable? = nil
}

extension EnvironmentValues {
    var inWindowModalStack: InWindowModalStack {
        get { self[InWindowModalStackKey.self] }
        set { self[InWindowModalStackKey.self] = newValue }
    }

    /// The stack entry this view is drawn in, nil outside the stack.
    var inWindowModalEntryID: AnyHashable? {
        get { self[InWindowModalEntryIDKey.self] }
        set { self[InWindowModalEntryIDKey.self] = newValue }
    }
}

extension View {
    /// Drop-in for `.sheet(item:)`: presents `content` as an in-window modal while `item` is non-nil.
    func inWindowSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
        modifier(InWindowSheetModifier(item: item, sheet: content))
    }
}

private struct InWindowSheetModifier<Item: Identifiable, Sheet: View>: ViewModifier {
    @Binding var item: Item?
    let sheet: (Item) -> Sheet
    @Environment(\.inWindowModalStack) private var stack
    /// Scopes the entry id to this modifier, so two presenters can't collide on equal item ids.
    @State private var token = UUID()
    @State private var presentedID: AnyHashable?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: sync)
            .onChange(of: item.map { AnyHashable($0.id) }) { _, _ in sync() }
            .onDisappear {
                if let presentedID {
                    stack.dismiss(id: presentedID)
                }
            }
    }

    private func sync() {
        let next = item.map { AnyHashable([AnyHashable(token), AnyHashable($0.id)]) }
        guard next != presentedID else {
            return
        }
        if let presentedID {
            stack.dismiss(id: presentedID)
        }
        if let item, let next {
            stack.present(id: next, AnyView(sheet(item)))
        }
        presentedID = next
    }
}

/// One modal over the window: a hit-testable scrim, so clicks never reach the panes underneath, and the
/// modal centred and scaled down to fit a window shorter or narrower than it.
struct ModalLayer<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var contentSize: CGSize = .zero

    private static var margin: CGFloat { ShellMetrics.gap }
    private static var scrimOpacity: Double { 0.5 }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppPalette.shadow.swiftUI.opacity(Self.scrimOpacity)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                content
                    .fixedSize()
                    .background(GeometryReader { Color.clear.preference(key: ModalSizeKey.self, value: $0.size) })
                    .scaleEffect(fit(in: proxy.size))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onPreferenceChange(ModalSizeKey.self) { contentSize = $0 }
        .ignoresSafeArea()
    }

    private func fit(in size: CGSize) -> CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return 1
        }
        let margin = Self.margin * 2
        return max(0.1, min(1, (size.width - margin) / contentSize.width, (size.height - margin) / contentSize.height))
    }
}

private struct ModalSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// How modals come and go: backdrop and modal fade together, no scale. A closing modal stays mounted and
/// stops taking clicks until its fade-out ends, so a second click can't act twice.
enum ModalFade {
    static let fadeIn = 0.18 * slowdown
    static let fadeOut = 0.14 * slowdown

    /// Stretches the modal animations: 1 in the app. DEBUG renders set QUESTMASTER_ANIMATION_SLOWDOWN so an
    /// animation recording can sample each frame (its GIF then plays the frames back at real speed).
    static let slowdown: Double = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["QUESTMASTER_ANIMATION_SLOWDOWN"].flatMap(Double.init) ?? 1
        #else
        return 1
        #endif
    }()
}

extension View {
    /// Fades in on insertion; fades out while `closing`, ignoring clicks.
    func modalFade(closing: Bool) -> some View {
        opacity(closing ? 0 : 1)
            .allowsHitTesting(!closing)
            .animation(.easeOut(duration: closing ? ModalFade.fadeOut : ModalFade.fadeIn), value: closing)
            .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: ModalFade.fadeIn)), removal: .identity))
    }
}

struct InWindowModalStackView: View {
    @ObservedObject var stack: InWindowModalStack

    var body: some View {
        ZStack {
            ForEach(stack.entries) { entry in
                ModalLayer { entry.view }
                    .modalFade(closing: entry.closing)
                    .environment(\.inWindowModalStack, stack)
                    .environment(\.inWindowModalEntryID, entry.id)
            }
        }
    }
}

/// Draws the modal stack over the whole window. Hidden while the stack is empty so it never takes a click.
/// Whenever a modal opens or starts closing the host takes first responder, so focus never stays in a modal
/// underneath or one fading out, and keys a modal doesn't claim never reach the terminal; a modal's own text
/// field still takes focus as it appears. Once the last modal's fade-out ends, focus goes back to what had it
/// before the first one opened, or to `onEmpty` when that is gone.
final class InWindowModalHost: NSHostingView<InWindowModalStackView> {
    var onEmpty: (() -> Void)?
    private var subscription: AnyCancellable?
    private var openCount = 0
    private weak var focusBeforeModals: NSResponder?

    init(stack: InWindowModalStack) {
        super.init(rootView: InWindowModalStackView(stack: stack))
        // Sized only by the edges it's pinned to: by default a hosting view publishes its content's size as
        // constraints, which would drag the window toward the modal's size.
        sizingOptions = []
        isHidden = stack.entries.isEmpty
        openCount = stack.entries.filter { !$0.closing }.count
        subscription = stack.$entries.sink { [weak self] entries in
            self?.entriesWillChange(to: entries)
        }
    }

    @available(*, unavailable)
    required init(rootView: InWindowModalStackView) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Visible while anything is drawn, closing modals included. Runs before `entries` changes, from whichever
    /// path opened or closed a modal.
    private func entriesWillChange(to entries: [InWindowModalStack.Entry]) {
        let wasDrawing = !isHidden
        if !wasDrawing, !entries.isEmpty {
            focusBeforeModals = Self.focusTarget(window?.firstResponder)
        }
        isHidden = entries.isEmpty
        let nextOpenCount = entries.filter { !$0.closing }.count
        if nextOpenCount != openCount {
            window?.makeFirstResponder(self)
        }
        openCount = nextOpenCount
        if wasDrawing, entries.isEmpty {
            restoreFocus()
        }
    }

    private func restoreFocus() {
        if let view = focusBeforeModals as? NSView, let window, view.window === window, window.makeFirstResponder(view) {
            return
        }
        onEmpty?()
    }

    /// A text field being edited reports the window's shared field editor; focus goes back to the field itself.
    /// The window itself (nothing focused) counts as nothing.
    private static func focusTarget(_ responder: NSResponder?) -> NSResponder? {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return field
        }
        return responder is NSWindow ? nil : responder
    }
}
