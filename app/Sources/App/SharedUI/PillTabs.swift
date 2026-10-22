import AppKit
import QuestmasterCore
import SwiftUI

/// Pill tabs (new-session.svg's agent tabs, settings-models.svg's agent tabs and sidebar): a 26-high pill
/// with scalloped ends, a 30pt disc holding the icon 10 in, and the 10pt label on a baseline 17 down,
/// 45 in. Selected: a controlBorder outline and disc. While the row has keyboard focus the selected tab
/// turns brass, as the forms mark a focused select.
struct PillTab: View {
    let title: String
    let icon: NSImage?
    let selected: Bool
    var focused = false
    /// The selected label's colour: bright for the agent tabs, gold for Settings' sections.
    var selectedLabelColor = AppPalette.questLogRowSelected

    var body: some View {
        ZStack(alignment: .topLeading) {
            PillTabShape()
                .fill(AppPalette.item.swiftUI)
                .overlay(PillTabShape().stroke(borderColor.swiftUI, lineWidth: 2 * Token.Size.divider))
                .clipShape(PillTabShape())
                .frame(height: PillTabMetrics.height)
                .offset(y: PillTabMetrics.discOverhang)
            disc
                .offset(x: PillTabMetrics.discLead)
            BaselineText(title, font: AppFonts.pillTab, color: labelColor, baseline: PillTabMetrics.labelBaseline + PillTabMetrics.discOverhang)
                .lineLimit(1)
                .offset(x: PillTabMetrics.labelLead)
        }
        .frame(maxWidth: .infinity, minHeight: PillTabMetrics.rowHeight, maxHeight: PillTabMetrics.rowHeight, alignment: .topLeading)
        .contentShape(PillTabShape())
    }

    private var borderColor: NSColor {
        guard selected else {
            return AppPalette.line
        }
        return focused ? AppPalette.brass : AppPalette.controlBorder
    }

    private var labelColor: NSColor {
        guard selected else {
            return AppPalette.questLogRow
        }
        return focused ? AppPalette.warn : selectedLabelColor
    }

    private var disc: some View {
        ZStack {
            Circle()
                .fill((selected ? AppPalette.panel : AppPalette.item).swiftUI)
            Circle()
                .strokeBorder(borderColor.swiftUI, lineWidth: Token.Size.divider)
            if let icon {
                Image(nsImage: icon)
            }
        }
        .frame(width: PillTabMetrics.discDiameter, height: PillTabMetrics.discDiameter)
    }
}

/// A row of pill tabs at equal widths, 10 apart.
struct PillTabRow<ID: Hashable>: View {
    struct Tab {
        let id: ID
        let title: String
        let icon: NSImage?
    }

    let tabs: [Tab]
    let selectedID: ID
    var focused = false
    var onSelect: (ID) -> Void

    var body: some View {
        HStack(spacing: PillTabMetrics.spacing) {
            ForEach(tabs, id: \.id) { tab in
                PillTab(title: tab.title, icon: tab.icon, selected: tab.id == selectedID, focused: focused)
                    .onTapGesture { onSelect(tab.id) }
                    .accessibilityAddTraits(tab.id == selectedID ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

extension PillTabRow.Tab where ID == String {
    /// An agent's tab: its display name and its mark, drawn so the mark's ink is about 20 across, as the
    /// design's Claude, Codex and Pi marks are.
    static func agent(_ agent: String) -> Self {
        Self(id: agent, title: AgentKind.displayName(for: agent), icon: TrackerAgentMark.image(for: agent, side: PillTabMetrics.logoSide(for: agent), tint: AppPalette.agentMarkTint))
    }
}

enum PillTabMetrics {
    static let height: CGFloat = 26
    static let discDiameter: CGFloat = 30
    /// The disc stands 2 above and below the pill.
    static let discOverhang: CGFloat = (discDiameter - height) / 2
    static let rowHeight: CGFloat = discDiameter
    static let discLead: CGFloat = 10
    static let iconSide: CGFloat = 20
    static let labelLead: CGFloat = 45
    static let labelBaseline: CGFloat = 17
    static let spacing: CGFloat = 10

    /// The marks' SVGs pad their ink differently: Pi's fills 470 of its 800 units, OpenCode's 20 of 24.
    static func logoSide(for agent: String) -> CGFloat {
        switch AgentKind(name: agent) {
        case .pi:
            return iconSide * 800 / 470
        case .opencode:
            return iconSide * 24 / 20
        case .claude, .codex, .shell, .unknown:
            return iconSide
        }
    }
}

/// The pill's outline: new-session.svg's 160 x 26 tab, whose scalloped ends keep their own curves (the
/// left one 7.125 deep, the right 7.841) while the straight runs stretch.
struct PillTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let sy = rect.height / PillTabMetrics.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x, y: rect.minY + y * sy) }
        func r(_ x: CGFloat, _ y: CGFloat) -> CGPoint { p(w - x, y) }
        var path = Path()
        path.move(to: p(7.1249, 26))
        path.addCurve(to: p(4.4801, 20.908), control1: p(7.1249, 26), control2: p(7.0291, 22.736))
        path.addCurve(to: p(1.2973, 20.429), control1: p(2.2009, 19.08), control2: p(1.2973, 20.429))
        path.addLine(to: p(0, 13))
        path.addLine(to: p(1.2973, 5.571))
        path.addCurve(to: p(4.4801, 5.092), control1: p(1.2973, 5.571), control2: p(2.201, 6.92))
        path.addCurve(to: p(7.1249, 0), control1: p(7.0292, 3.264), control2: p(7.1249, 0))
        path.addLine(to: r(7.841, 0))
        path.addCurve(to: r(4.93, 5.092), control1: r(7.841, 0), control2: r(7.736, 3.264))
        path.addCurve(to: r(1.428, 5.571), control1: r(2.422, 6.92), control2: r(1.428, 5.571))
        path.addLine(to: r(0, 13))
        path.addLine(to: r(1.428, 20.429))
        path.addCurve(to: r(4.93, 20.908), control1: r(1.428, 20.429), control2: r(2.422, 19.08))
        path.addCurve(to: r(7.841, 26), control1: r(7.736, 22.736), control2: r(7.841, 26))
        path.closeSubpath()
        return path
    }
}
