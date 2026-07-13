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
    let spec: DestructiveConfirmation
    let onDecision: (Bool) -> Void

    var body: some View {
        ModalSheetScaffold(
            title: spec.title,
            footerText: "",
            errorMessage: nil,
            titleColor: AppPalette.deleted,
            cancelLabel: spec.cancelLabel,
            onCancel: { onDecision(false) },
            primaryLabel: spec.confirmLabel,
            onPrimary: { onDecision(true) },
            destructivePrimary: true
        ) {
            Text(spec.message)
                .font(AppFonts.body.swiftUI)
                .foregroundStyle(AppPalette.muted.swiftUI)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 16)
        }
        .frame(width: 420)
        .background(AppPalette.panel.swiftUI)
        .background(SheetKeyEventMonitor { event in
            if Keymap.NewSession.cancel.matches(event.keyCode) {
                onDecision(false)
                return true
            }
            if Keymap.NewSession.create.matches(event.charactersIgnoringModifiers) {
                onDecision(true)
                return true
            }
            return false
        })
    }
}
