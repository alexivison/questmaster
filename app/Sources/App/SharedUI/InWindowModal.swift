import AppKit
import Combine
import SwiftUI

/// The app's modals, drawn inside the main window instead of as system sheets. SwiftUI's `.sheet` on macOS
/// is a titled sheet window whose frame puts a visual-effect panel, a rounded corner mask and a light edge
/// behind the content, and none of that can be cleared reliably, so the scooped corners would show it.
/// Every modal is pushed here by `.inWindowSheet(item:)` and drawn by `InWindowModalHost`, newest on top.
@MainActor
final class InWindowModalStack: ObservableObject {
    // ponytail: one stack for the app's one main window; give each window its own if the app ever opens more.
    static let shared = InWindowModalStack()

    struct Entry: Identifiable {
        let id: AnyHashable
        let view: AnyView
    }

    @Published private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    func present(id: AnyHashable, _ view: AnyView) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, view: view))
    }

    func dismiss(id: AnyHashable) {
        entries.removeAll { $0.id == id }
    }
}

private struct InWindowModalStackKey: EnvironmentKey {
    @MainActor static var defaultValue: InWindowModalStack { .shared }
}

extension EnvironmentValues {
    var inWindowModalStack: InWindowModalStack {
        get { self[InWindowModalStackKey.self] }
        set { self[InWindowModalStackKey.self] = newValue }
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

struct InWindowModalStackView: View {
    @ObservedObject var stack: InWindowModalStack

    var body: some View {
        ZStack {
            ForEach(stack.entries) { entry in
                ModalLayer { entry.view }
            }
        }
    }
}

/// Draws the modal stack over the whole window, above the Quest Log. Hidden while the stack is empty so
/// it never takes a click. When a modal opens it takes first responder, so keys a modal doesn't claim
/// never reach the terminal; a modal's own text field still takes focus as it appears. `onEmpty` hands
/// focus back once the last modal closes.
final class InWindowModalHost: NSHostingView<InWindowModalStackView> {
    var onEmpty: (() -> Void)?
    private var subscription: AnyCancellable?

    init(stack: InWindowModalStack) {
        super.init(rootView: InWindowModalStackView(stack: stack))
        isHidden = stack.isEmpty
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

    private func entriesWillChange(to entries: [InWindowModalStack.Entry]) {
        let wasHidden = isHidden
        isHidden = entries.isEmpty
        if wasHidden, !entries.isEmpty {
            window?.makeFirstResponder(self)
        } else if !wasHidden, entries.isEmpty {
            onEmpty?()
        }
    }
}
