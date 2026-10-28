import QuestmasterCore
import SwiftUI

/// Presents `DestructiveConfirmation` prompts (e.g. session delete) as a
/// SwiftUI sheet, matching how `NewSessionSheetPresenter`/`NewQuestSheetPresenter`
/// present their sheets — so all three modals share one presentation mechanism
/// instead of the confirmation living in a separately-floating NSPanel.
@MainActor
final class DestructiveConfirmationPresenter: ObservableObject {
    @Published var presentation: DestructiveConfirmationRequest?

    func present(_ spec: DestructiveConfirmation, onDecision: @escaping (Bool) -> Void) {
        presentation = DestructiveConfirmationRequest(spec: spec, onDecision: onDecision)
    }

    func dismiss() {
        presentation = nil
    }
}

struct DestructiveConfirmationRequest: Identifiable {
    let id = UUID()
    let spec: DestructiveConfirmation
    let onDecision: (Bool) -> Void
}

struct DestructiveConfirmationSheetView: View {
    static let width: CGFloat = 420
    let spec: DestructiveConfirmation
    let onDecision: (Bool) -> Void

    var body: some View {
        ModalSheetScaffold(
            title: spec.title,
            errorMessage: nil,
            titleColor: AppPalette.deleted,
            cancelLabel: spec.cancelLabel,
            onCancel: { onDecision(false) },
            primaryLabel: spec.confirmLabel,
            onPrimary: { onDecision(true) },
            destructivePrimary: true
        ) {
            // The header leaves 10 above the message; 10 more under it and the footer's own 10 make the 20 between
            // blocks.
            Text(spec.message)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.section)
                .padding(.bottom, Space.item)
        }
        .frame(width: Self.width)
        .scoopedPanel()
        .background(SheetKeyEventMonitor(onKeyDown: ModalKeyActions(
            context: { ModalKeyContext(focus: nil, fieldCount: 0, submitting: false, submits: true) },
            submit: { onDecision(true) },
            cancel: { onDecision(false) }
        ).handle))
    }
}
