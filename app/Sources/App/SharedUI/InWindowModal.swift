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
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration(.fast)) { [weak self] in
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

    /// Whether a view drawn here may take keyboard focus, asked when the grab runs: outside the stack always;
    /// inside it only while its modal is open and on top, as `SheetKeyEventMonitor` takes keys. A closing modal
    /// (fading out, or gone by the time a queued grab runs) never takes focus back from where the shell put it.
    var modalAllowsFocus: @MainActor () -> Bool {
        { [stack = inWindowModalStack, entryID = inWindowModalEntryID] in stack.isTop(entryID) }
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
/// modal centred and scaled down to fit a window shorter or narrower than it. It fades in as it comes, the scrim
/// alone and the modal with a scale up from `enterScale`; both run back when `closing`, which also stops clicks.
struct ModalLayer<Content: View>: View {
    let closing: Bool
    @ViewBuilder var content: Content
    @State private var contentSize: CGSize = .zero
    /// False for the first frame, so the entrance animates from the hidden state.
    @State private var entered = false

    private static var margin: CGFloat { ShellMetrics.gap }
    private static var scrimOpacity: Double { 0.35 }
    private static var enterScale: CGFloat { 0.97 }

    private var isShown: Bool { entered && !closing }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                AppPalette.shadow.swiftUI.opacity(isShown ? Self.scrimOpacity : 0)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                content
                    .fixedSize()
                    .background(GeometryReader { Color.clear.preference(key: ModalSizeKey.self, value: $0.size) })
                    .scaleEffect(fit(in: proxy.size) * (isShown ? 1 : Self.enterScale))
                    .opacity(isShown ? 1 : 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onPreferenceChange(ModalSizeKey.self) { contentSize = $0 }
        .ignoresSafeArea()
        .allowsHitTesting(!closing)
        .animation(Motion.animation(closing ? .fast : .standard), value: isShown)
        .onAppear { entered = true }
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

struct InWindowModalStackView: View {
    @ObservedObject var stack: InWindowModalStack

    var body: some View {
        ZStack {
            ForEach(stack.entries) { entry in
                ModalLayer(closing: entry.closing) { entry.view }
                    .environment(\.inWindowModalStack, stack)
                    .environment(\.inWindowModalEntryID, entry.id)
            }
        }
    }
}

/// Draws the modal stack over the whole window. Hidden while the stack is empty so it never takes a click.
/// Whenever a modal opens the host takes first responder, so focus never stays in the modal it covers and keys
/// a modal doesn't claim never reach the terminal; a modal's own text field still takes focus as it appears.
/// When a modal closes, focus goes back to what had it in the modal it uncovers (the host when that is gone).
/// Once the last modal's fade-out ends, focus goes back to what had it before the first one opened, or to
/// `onEmpty` when that is gone or a shell focus request came in meanwhile (`deferFocus`).
final class InWindowModalHost: NSHostingView<InWindowModalStackView> {
    var onEmpty: (() -> Void)?
    /// A modal started or stopped being drawn: the panes under it lose or get back their focus looks.
    var onDrawingChange: (() -> Void)?
    private var subscription: AnyCancellable?
    private var openCount = 0
    private var topID: AnyHashable?
    private var focusBeforeModals: FocusRecord?
    /// What had focus in each modal when a child covered it.
    private var focusUnderChild: [AnyHashable: FocusRecord] = [:]

    /// A view that had focus, with a text field's whole selection, so typing carries on where it was.
    private struct FocusRecord {
        weak var responder: NSResponder?
        let selection: NSRange?

        /// `responder`: the focus target (a field, not its field editor).
        init?(_ responder: NSResponder?) {
            guard let responder else {
                return nil
            }
            self.responder = responder
            selection = (responder as? NSTextField)?.currentEditor()?.selectedRange
        }
    }

    init(stack: InWindowModalStack) {
        super.init(rootView: InWindowModalStackView(stack: stack))
        // Sized only by the edges it's pinned to: by default a hosting view publishes its content's size as
        // constraints, which would drag the window toward the modal's size.
        sizingOptions = []
        isHidden = stack.entries.isEmpty
        openCount = stack.entries.filter { !$0.closing }.count
        topID = stack.top?.id
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

    /// Whether a modal is drawn, closing ones included: the keys go to the modals, not the panes.
    var isDrawing: Bool { !isHidden }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A shell focus request (a region, the terminal, the dock) while a modal is drawn: the keys stay on the
    /// modal, and the request replaces the focus recorded before the first modal, so `onEmpty` carries it out
    /// once the last modal has faded out. False when nothing is drawn and the caller should focus now.
    func deferFocus() -> Bool {
        guard !isHidden else {
            return false
        }
        focusBeforeModals = nil
        return true
    }

    /// Visible while anything is drawn, closing modals included. Runs before `entries` changes, from whichever
    /// path opened or closed a modal.
    private func entriesWillChange(to entries: [InWindowModalStack.Entry]) {
        let wasDrawing = !isHidden
        if !wasDrawing, !entries.isEmpty {
            focusBeforeModals = FocusRecord(Self.focusTarget(window?.firstResponder))
        }
        isHidden = entries.isEmpty
        if wasDrawing != isDrawing {
            onDrawingChange?()
        }
        let open = entries.filter { !$0.closing }
        let nextTopID = open.last?.id
        if open.count > openCount, let topID, let record = FocusRecord(Self.focusTarget(window?.firstResponder)) {
            focusUnderChild[topID] = record
        }
        if open.count != openCount {
            let uncovered = nextTopID.flatMap { focusUnderChild[$0] }
            if !refocus(uncovered) {
                window?.makeFirstResponder(self)
            }
        }
        focusUnderChild = focusUnderChild.filter { id, _ in id != nextTopID && open.contains { $0.id == id } }
        openCount = open.count
        topID = nextTopID
        if wasDrawing, entries.isEmpty {
            restoreFocus()
        }
    }

    private func restoreFocus() {
        if !refocus(focusBeforeModals) {
            onEmpty?()
        }
    }

    private func refocus(_ record: FocusRecord?) -> Bool {
        guard let view = record?.responder as? NSView, let window, view.window === window, window.makeFirstResponder(view) else {
            return false
        }
        // Taking focus selects a field's whole text; put its selection back, clamped to the text it has now, so
        // typing doesn't replace it.
        if let selection = record?.selection, let editor = (view as? NSTextField)?.currentEditor() {
            let length = (editor.string as NSString).length
            let location = min(selection.location, length)
            editor.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        }
        return true
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
