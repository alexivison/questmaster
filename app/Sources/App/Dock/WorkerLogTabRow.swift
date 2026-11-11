import QuestmasterCore
import SwiftUI

/// The Worker Log's tab row insets: the row ends `bottomInset` above the panel's bottom edge, and the bottom corners'
/// scoop reaches its radius in beside the row, so the tabs keep `Space.item` clear of it.
enum WorkerLogTabMetrics {
    static let bottomInset = Space.item
    /// What the row takes from the panel's bottom: the row and the inset under it.
    static let reserved = TextTabMetrics.height + bottomInset
    static let sideInset = ScoopedRectangle.radius + Space.item
}

/// The Worker Log's tabs: All, then one per worker in the tracker's order, pinned under the feed.
struct WorkerLogTabRow: View {
    let workers: [WorkerLogWorker]
    /// The selected worker's id; nil selects All.
    let selectedID: String?
    /// Whether the panel has the keys, which a selected tab's label follows.
    let areaFocused: Bool
    /// The tab under the pointer, for the renders.
    var previewHoveredIndex: Int?
    let onSelect: (String?) -> Void

    var body: some View {
        TextTabRow(
            titles: ["All"] + workers.map(\.name),
            selectedIndex: selectedIndex,
            areaFocused: areaFocused,
            previewHoveredIndex: previewHoveredIndex,
            onSelect: { index in onSelect(index == 0 ? nil : workers[index - 1].id) }
        )
    }

    /// Index 0 is All; a worker's tab follows it in the tracker's order.
    private var selectedIndex: Int {
        selectedID.flatMap { id in workers.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
    }
}
