import AppKit
import QuestmasterCore
import SwiftUI

/// The Projects section's state: the highlighted row, arrange mode's copy of the order, the edit sheet it opens and the
/// error a failed save shows. The rows come from the runtime store, so they follow each snapshot.
@MainActor
final class SettingsProjectsModel: ObservableObject {
    /// Set while arrange mode is on: the local order the rows show, until Save or Cancel.
    @Published private(set) var arrangement: ProjectArrangement?
    /// The highlighted row outside arrange mode. Arranging keeps the highlight on `arrangement`.
    @Published private(set) var highlight = 0
    @Published var errorMessage: String?
    /// The edit sheet, a child of Settings while it is set.
    @Published var editing: ProjectEditPresentation?

    private let runtime: RuntimeStore
    private let mutationClient: ServeMutationSending

    init(runtime: RuntimeStore, mutationClient: ServeMutationSending) {
        self.runtime = runtime
        self.mutationClient = mutationClient
    }

    var isArranging: Bool {
        arrangement != nil
    }

    /// The projects in the order the list shows them: the snapshot's, or the arranged copy while arranging.
    var projectRows: [TrackerProject] {
        let projects = runtime.snapshot.tracker.projects
        return arrangement?.projects(from: projects) ?? projects
    }

    /// The folders that hold sessions but belong to no project. Arranging hides them: the arrangement covers projects only.
    var folderRows: [TrackerUnlistedFolder] {
        isArranging ? [] : runtime.snapshot.tracker.unlistedFolders
    }

    /// Every row in the order the highlight moves through them: the projects, then the folders.
    var entries: [ProjectListEntry] {
        ProjectListEntry.list(projects: projectRows, folders: folderRows)
    }

    /// The highlighted row's index, held inside the rows as they are now.
    var highlightIndex: Int {
        ProjectListCursor.moved(from: arrangement?.highlight ?? highlight, by: 0, count: entries.count)
    }

    /// Highlights a row: a click on it, or the cursor's step.
    func highlightRow(_ index: Int) {
        if arrangement != nil {
            arrangement?.setHighlight(index)
        } else {
            highlight = ProjectListCursor.moved(from: index, by: 0, count: entries.count)
        }
    }

    func moveHighlight(by delta: Int) {
        highlightRow(highlightIndex + delta)
    }

    /// The Projects keys, taken before the shared modal keys (`ModalKeys`), which move the highlight with j and k. False
    /// leaves the press to them.
    func handleKey(_ press: Keymap.KeyPress) -> Bool {
        if isArranging {
            return handleArrangingKey(press)
        }
        if Keymap.matches(press, .arrangeProjects) {
            beginArrange()
            return true
        }
        if Keymap.matches(press, .addProject) {
            addProject()
            return true
        }
        if Keymap.matches(press, .edit) {
            editRow(at: highlightIndex)
            return true
        }
        return false
    }

    /// Return: Save while arranging, otherwise edit the highlighted row.
    func submit() {
        if isArranging {
            saveArrange()
        } else {
            editRow(at: highlightIndex)
        }
    }

    /// Arrange mode starts from the snapshot's order, with the highlight where it is.
    func beginArrange() {
        guard !projectRows.isEmpty else {
            return
        }
        errorMessage = nil
        arrangement = ProjectArrangement(projectIDs: runtime.snapshot.tracker.projects.map(\.id), highlight: highlightIndex)
    }

    /// Cancel: the local order is dropped, and the highlight stays on the row it was on.
    func cancelArrange() {
        guard let arrangement else {
            return
        }
        highlight = arrangement.highlight
        self.arrangement = nil
        errorMessage = nil
    }

    func moveArrangedRow(at index: Int, by delta: Int) {
        highlightRow(index)
        arrangement?.moveHighlightedRow(by: delta)
    }

    /// Save sends the whole order. Nothing moved leaves arrange mode without a request.
    func saveArrange() {
        guard let saved = arrangement else {
            return
        }
        do {
            guard let request = try saved.reorderRequest() else {
                leaveArrange(saved)
                return
            }
            send(request) { [weak self] in
                self?.leaveArrange(saved)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func editRow(at index: Int) {
        let entries = entries
        guard entries.indices.contains(index) else {
            return
        }
        highlightRow(index)
        openEdit(entries[index].editDraft)
    }

    /// The add key and the header's +: Add Project, with the highlighted folder's path filled in.
    func addProject() {
        guard !isArranging else {
            return
        }
        openEdit(highlightedEntry?.addDraft ?? ProjectEditDraft.adding())
    }

    private var highlightedEntry: ProjectListEntry? {
        let entries = entries
        guard entries.indices.contains(highlightIndex) else {
            return nil
        }
        return entries[highlightIndex]
    }

    private func handleArrangingKey(_ press: Keymap.KeyPress) -> Bool {
        if Keymap.matches(press, .moveRowUp) {
            arrangement?.moveHighlightedRow(by: -1)
            return true
        }
        if Keymap.matches(press, .moveRowDown) {
            arrangement?.moveHighlightedRow(by: 1)
            return true
        }
        // Arrange, add and edit mean nothing while arranging, so their presses are taken and do nothing.
        return Keymap.matches(press, .arrangeProjects) || Keymap.matches(press, .addProject) || Keymap.matches(press, .edit)
    }

    /// Ends arrange mode with the highlight where the arranged list left it.
    private func leaveArrange(_ saved: ProjectArrangement) {
        highlight = saved.highlight
        arrangement = nil
        errorMessage = nil
    }

    private func openEdit(_ draft: ProjectEditDraft) {
        errorMessage = nil
        editing = ProjectEditPresentation(draft: draft, mutationClient: mutationClient)
    }

    private func send(_ request: ServeMutationRequest, onSuccess: @escaping () -> Void) {
        mutationClient.send(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                switch result {
                case .success:
                    onSuccess()
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
