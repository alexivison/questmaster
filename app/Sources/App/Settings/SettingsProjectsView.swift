import AppKit
import QuestmasterCore
import SwiftUI

/// The Projects section's own layout: the header's baseline `Space.section` down, its rule and rows as the Models
/// section lays out its own, and the header icons on the title's line.
enum SettingsProjectsMetrics {
    static let headerDrop = Space.section
    /// The header icons' boxes sit 15 above the title's baseline, so their centres fall on the title's middle.
    static let iconLift = Space.row * 3
    /// The empty list's room, under the rule.
    static let emptyHeight: CGFloat = 300
    /// From the last project row to the folders' title baseline: a group of blocks apart.
    static let folderSectionGap = Space.group
}

/// Settings > Projects (settings-projects-mock.png): the header with its rule, then the projects in the user's order. The
/// header's icons arrange the list and add a project; arranging swaps them for cancel and save. The edit sheet is a
/// child modal over Settings.
struct SettingsProjectsView: View {
    @ObservedObject var model: SettingsProjectsModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            BaselineText("Projects", font: AppFonts.settingsSectionTitle, color: AppPalette.text, baseline: 0)
            headerIcons
            SettingsSectionRule(width: SettingsMetrics.columnWidth)
                .offset(y: SettingsMetrics.ruleDrop)
            projectList
                .offset(y: SettingsMetrics.firstRowDrop)
        }
        .frame(width: SettingsMetrics.columnWidth, alignment: .topLeading)
        .offset(y: SettingsProjectsMetrics.headerDrop)
        .inWindowSheet(item: $model.editing) { presentation in
            ProjectEditSheetView(presentation: presentation) {
                model.editing = nil
            }
        }
    }

    private var headerIcons: some View {
        HStack(spacing: Space.item) {
            if model.isArranging {
                ChromeIconButton(symbolName: "xmark", accessibilityLabel: "Cancel arranging", tooltip: "Cancel (Esc)", tint: AppPalette.gitRed, action: model.cancelArrange)
                ChromeIconButton(symbolName: "checkmark", accessibilityLabel: "Save order", tooltip: "Save order (Return)", tint: AppPalette.gitGreen, action: model.saveArrange)
            } else {
                ChromeIconButton(symbolName: "arrow.up.arrow.down", accessibilityLabel: "Arrange projects", tooltip: "Arrange projects (R)", action: model.beginArrange)
                ChromeIconButton(symbolName: "plus", accessibilityLabel: "Add project", tooltip: "Add project (⌘T)", action: model.addProject)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .offset(y: -SettingsProjectsMetrics.iconLift)
    }

    @ViewBuilder
    private var projectList: some View {
        if model.entries.isEmpty {
            EmptyState()
                .frame(width: SettingsMetrics.columnWidth, height: SettingsProjectsMetrics.emptyHeight)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: ProjectRowMetrics.rowSpacing) {
                    ForEach(Array(model.projectRows.enumerated()), id: \.element.id) { index, project in
                        SettingsProjectRow(
                            project: project,
                            look: .project(highlighted: index == model.highlightIndex, arranging: model.isArranging),
                            arranging: model.isArranging,
                            onSelect: { model.highlightRow(index) },
                            onEdit: { model.editRow(at: index) },
                            onMove: { model.moveArrangedRow(at: index, by: $0) }
                        )
                    }
                }
                folderSection
            }
            .frame(width: SettingsMetrics.columnWidth, alignment: .topLeading)
        }
    }

    /// Folders that hold sessions but belong to no project. Their rows follow the projects in the one highlight order, so
    /// a folder's index starts after the last project's.
    @ViewBuilder
    private var folderSection: some View {
        let folders = model.folderRows
        if !folders.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    BaselineText("Folders without a project", font: AppFonts.settingsSectionTitle, color: AppPalette.text, baseline: 0)
                    SettingsSectionRule(width: SettingsMetrics.columnWidth)
                        .offset(y: SettingsMetrics.ruleDrop)
                }
                .frame(width: SettingsMetrics.columnWidth, height: SettingsMetrics.firstRowDrop, alignment: .topLeading)
                VStack(spacing: ProjectRowMetrics.rowSpacing) {
                    ForEach(Array(folders.enumerated()), id: \.element.id) { offset, folder in
                        let index = model.projectRows.count + offset
                        SettingsFolderRow(
                            folder: folder,
                            look: .folder(highlighted: index == model.highlightIndex),
                            onSelect: { model.highlightRow(index) },
                            onAdd: { model.editRow(at: index) }
                        )
                    }
                }
            }
            .padding(.top, SettingsProjectsMetrics.folderSectionGap)
        }
    }
}
