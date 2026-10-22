import AppKit
import QuestmasterCore
import SwiftUI

/// Pill tabs (new-session.svg's agent tabs, settings-models.svg's agent tabs and sidebar): a 26-high pill
/// with scalloped ends, a 30pt disc holding the icon 10 in, and the 10pt label on a baseline 17 down,
/// 45 in. A tab without an icon (artifacts.svg's Session/All) has no disc: the pill alone, its label centred on
/// the same baseline. It draws its `OutlineLook`: the outline and disc ring in its border colour, the label in its
/// label colour, and a highlighted or selected tab's disc recessed to the panel colour. It is one accessibility
/// element: its label, "Selected" as the value while selected, and its help.
struct PillTab: View {
    let title: String
    let icon: NSImage?
    let look: OutlineLook
    let selected: Bool
    let help: String
    let accessibilityLabel: String

    var body: some View {
        tab
            .help(help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var tab: some View {
        if icon == nil {
            pill
                .overlay {
                    BaselineText(title, font: AppFonts.pillTab, color: labelColor, baseline: PillTabMetrics.labelBaseline)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(PillTabShape())
        } else {
            withDisc
        }
    }

    private var pill: some View {
        PillTabShape()
            .fill(AppPalette.item.swiftUI)
            .overlay(PillTabShape().stroke(borderColor.swiftUI, lineWidth: 2 * Token.Size.divider))
            .clipShape(PillTabShape())
            .frame(height: PillTabMetrics.height)
    }

    private var withDisc: some View {
        ZStack(alignment: .topLeading) {
            pill
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
        look.border.color
    }

    private var labelColor: NSColor {
        look.label.color
    }

    private var disc: some View {
        ZStack {
            Circle()
                .fill((look.recessed ? AppPalette.panel : AppPalette.item).swiftUI)
            Circle()
                .strokeBorder(borderColor.swiftUI, lineWidth: Token.Size.divider)
            if let icon {
                Image(nsImage: icon)
            }
        }
        .frame(width: PillTabMetrics.discDiameter, height: PillTabMetrics.discDiameter)
    }
}

/// A row of pill tabs at equal widths, 10 apart. The keys and a click move the selection. A row without keyboard
/// focus shows its selection one step dimmer.
struct PillTabRow<ID: Hashable>: View {
    struct Tab {
        let id: ID
        let title: String
        let icon: NSImage?
        let help: String
        let accessibilityLabel: String
    }

    let tabs: [Tab]
    let selectedID: ID
    let focused: Bool
    var spacing = PillTabMetrics.spacing
    var onSelect: (ID) -> Void

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(tabs, id: \.id) { tab in
                PillTab(
                    title: tab.title,
                    icon: tab.icon,
                    look: .tab(selected: tab.id == selectedID, areaFocused: focused),
                    selected: tab.id == selectedID,
                    help: tab.help,
                    accessibilityLabel: tab.accessibilityLabel
                )
                .onTapGesture { onSelect(tab.id) }
            }
        }
    }
}

extension PillTabRow.Tab where ID == String {
    /// An agent's tab: its display name and its mark, drawn so the mark's ink is about 20 across, as the
    /// design's Claude, Codex and Pi marks are.
    static func agent(_ agent: String) -> Self {
        let name = AgentKind.displayName(for: agent)
        return Self(
            id: agent,
            title: name,
            icon: TrackerAgentMark.image(for: agent, side: PillTabMetrics.logoSide(for: agent), tint: AppPalette.agentMarkTint),
            help: "Choose \(name)",
            accessibilityLabel: "Agent \(name)"
        )
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

    /// Pi's mark is a solid block, so at the line-drawn marks' 20pt it reads far larger (an ink area of
    /// about 245 against Claude's 140 and Codex's 155): it is drawn to their ink area instead, a 15.5pt
    /// square. Its SVG pads that ink to 470 of 800 units.
    static let piInkSide: CGFloat = 15.5

    /// The side each mark's image is drawn at for its ink to read at the same size: Claude's and Codex's
    /// SVGs fill their box, OpenCode's 20 of its 24 units, Pi's as above.
    static func logoSide(for agent: String) -> CGFloat {
        switch AgentKind(name: agent) {
        case .pi:
            return piInkSide * 800 / 470
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
