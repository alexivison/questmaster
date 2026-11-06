import AppKit
import Combine
import QuestmasterCore
import SwiftUI

@MainActor
final class TmuxSettingsPageModel: ObservableObject {
    typealias EditorOpening = (String, @escaping (Result<Void, Error>) -> Void) -> Void

    @Published var details: TmuxSettingsModel?
    @Published var checkResult: TmuxConfigCheck?
    @Published var operationErrors: [String] = []
    @Published var message: String?
    @Published var errorMessage: String?
    @Published var isBusy = false

    private let mutationClient: ServeMutationSending
    private let openEditor: EditorOpening
    private var hasLoaded = false

    init(mutationClient: ServeMutationSending, openEditor: @escaping EditorOpening) {
        self.mutationClient = mutationClient
        self.openEditor = openEditor
    }

    func loadIfNeeded() {
        guard !hasLoaded, details == nil else { return }
        hasLoaded = true
        refresh()
    }

    func refresh() {
        mutationClient.send(ServeMutationRequest(method: "tmux.config")) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let ack):
                    do {
                        let status = try ack.decoded(TmuxConfigStatus.self)
                        self.details = TmuxSettingsModel(status: status)
                        self.errorMessage = nil
                    } catch {
                        self.hasLoaded = false
                        self.errorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    self.hasLoaded = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func moveFocus(_ delta: Int) {
        details?.moveFocus(delta)
    }

    func performFocused() {
        guard let action = details?.focusedAction else { return }
        perform(action)
    }

    func perform(_ action: TmuxSettingsAction) {
        guard let details, details.canPerform(action), !isBusy else { return }
        self.details?.focus(action)
        errorMessage = nil
        message = nil
        checkResult = nil
        operationErrors = []
        switch action {
        case .openEditor:
            isBusy = true
            openEditor(details.status.config) { [weak self] result in
                DispatchQueue.main.async {
                    self?.isBusy = false
                    if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
                }
            }
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: details.status.config)])
        case .check:
            send("tmux.config.check") { [weak self] ack in
                let checked = try ack.decoded(TmuxConfigCheck.self)
                self?.checkResult = checked
                self?.message = checked.ok ? "Configuration is valid." : nil
            }
        case .reload:
            send("tmux.config.reload") { [weak self] ack in
                let result = try ack.decoded(TmuxConfigReload.self)
                self?.operationErrors = result.errors
                self?.message = result.errors.isEmpty ? "Configuration reloaded." : nil
                self?.refresh()
            }
        case .restart:
            send("tmux.server.restart") { [weak self] ack in
                let result = try ack.decoded(TmuxServerRestart.self)
                self?.message = result.restarted ? "Server restarted." : "Restart refused: \(result.sessions) sessions remain."
                self?.refresh()
            }
        }
    }

    private func send(_ method: String, completion: @escaping (ServeMutationAck) throws -> Void) {
        isBusy = true
        mutationClient.send(ServeMutationRequest(method: method)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                do {
                    switch result {
                    case .success(let ack): try completion(ack)
                    case .failure(let error): throw error
                    }
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct TmuxSettingsView: View {
    @ObservedObject var model: TmuxSettingsPageModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                header
                if let details = model.details {
                    status(details)
                    actions(details)
                    results
                } else if let error = model.errorMessage {
                    Text(error)
                        .foregroundStyle(AppPalette.textBody.swiftUI)
                }
            }
            .frame(width: SettingsMetrics.columnWidth, alignment: .leading)
        }
        .frame(width: SettingsMetrics.columnWidth)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.item) {
            Text("Tmux")
                .font(Font(AppFonts.settingsSectionTitle))
                .foregroundStyle(AppPalette.text.swiftUI)
            SettingsSectionRule(width: SettingsMetrics.columnWidth)
        }
        .padding(.top, Space.section)
    }

    private func status(_ details: TmuxSettingsModel) -> some View {
        VStack(alignment: .leading, spacing: Space.item) {
            Text(details.status.config)
                .textSelection(.enabled)
                .font(Font(AppFonts.settingsLabel))
                .foregroundStyle(AppPalette.textBody.swiftUI)
            Text("Server \(details.status.effectiveLabel) · \(details.serverCaption)")
            if details.showsEditedSinceStart { Text("Edited since the server started") }
            if details.showsEnforcedPending { Text("Questmaster settings change pending") }
            if details.showsNewerTemplate { Text("A newer built-in template is available. qm tmux config template prints it.") }
        }
        .font(Font(AppFonts.settingsDescription))
        .foregroundStyle(AppPalette.textBody.swiftUI)
    }

    private func actions(_ details: TmuxSettingsModel) -> some View {
        VStack(alignment: .leading, spacing: Space.item) {
            action(.openEditor, title: "Open in editor", caption: nil, details: details)
            action(.reveal, title: "Reveal in Finder", caption: nil, details: details)
            action(.check, title: "Check", caption: "Checks the config before applying it.", details: details)
            action(.reload, title: "Reload", caption: details.reloadCaption, details: details)
            action(.restart, title: "Restart server", caption: details.restartCaption, details: details)
        }
    }

    private func action(_ action: TmuxSettingsAction, title: String, caption: String?, details: TmuxSettingsModel) -> some View {
        let selected = details.focusedAction == action
        let look: RowLook = selected ? .highlighted : .rest
        return HStack(alignment: .top, spacing: Space.item) {
            Button(title) { model.perform(action) }
                .buttonStyle(OutlineButtonStyle(width: 160))
                .disabled(!details.canPerform(action) || model.isBusy)
            if let caption {
                Text(caption)
                    .font(Font(AppFonts.settingsDescription))
                    .foregroundStyle(AppPalette.textBody.swiftUI)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.perform(action) }
            }
        }
        .padding(Space.row)
        .stateRow(look, cornerRadius: Space.row)
    }

    @ViewBuilder
    private var results: some View {
        if let message = model.message {
            Text(message).foregroundStyle(AppPalette.textBody.swiftUI)
        }
        if let error = model.errorMessage {
            Text(error).foregroundStyle(AppPalette.textBody.swiftUI)
        }
        ForEach(Array((model.checkResult?.errors ?? model.operationErrors).enumerated()), id: \.offset) { _, error in
            Text(error)
                .textSelection(.enabled)
                .font(Font(AppFonts.settingsDescription))
                .foregroundStyle(AppPalette.textBody.swiftUI)
        }
    }
}
