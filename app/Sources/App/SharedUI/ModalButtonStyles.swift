import SwiftUI

/// The primary action button: the Quest Log's "Send forth".
struct GoldButtonStyle: ButtonStyle {
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        AngledButton(fill: .gold, width: width, configuration: configuration)
    }
}

/// The secondary button (e.g. "Cancel"): the Quest Log's "Edit".
struct OutlineButtonStyle: ButtonStyle {
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        AngledButton(fill: .plain, width: width, configuration: configuration)
    }
}

/// The destructive button (e.g. "Banish"): the Quest Log's "Abandon". Stays red regardless of theme, so a
/// destructive action keeps its "this is dangerous" signal.
struct DangerButtonStyle: ButtonStyle {
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        AngledButton(fill: .danger, width: width, configuration: configuration)
    }
}

private enum AngledButtonMetrics {
    /// The Quest Log design's buttons, 32 high, on the 5pt rhythm at 30, with a 1.5pt inner border and the label's
    /// baseline 19 down (the design's 20, moved up with the centre).
    static let height = ControlHeight.control
    static let designHeight: CGFloat = 32
    static let borderStrokeWidth: CGFloat = 3
    static let baseline: CGFloat = 19
    /// Narrower than the design's 200 so the modals' footers fit; a longer label widens the button.
    static let minWidth: CGFloat = 120
    static let labelInset = Space.section
    /// Figma's angular gradients turn around the button's left end in a space squashed to the button's
    /// shape: its 2015pt unit square is scaled by width / 1000 and height / 1000 (0.2 x 0.032 at 200 x 32).
    static let gradientSpan: CGFloat = 2015
    static let gradientUnit: CGFloat = 1000
    static let goldGradientOpacity = 0.4
    static let goldGradientShadow = 0.4
    static let pressedOpacity = 0.8
}

private struct AngledButton: View {
    enum Fill {
        case gold
        case plain
        case danger
    }

    let fill: Fill
    let width: CGFloat?
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(AppFonts.questLogButton.swiftUI)
            .foregroundStyle((isEnabled ? AppPalette.textBody : AppPalette.item).swiftUI)
            .lineLimit(1)
            .fixedSize()
            .alignmentGuide(.top) { $0[.firstTextBaseline] - AngledButtonMetrics.baseline }
            .padding(.horizontal, AngledButtonMetrics.labelInset)
            .frame(minWidth: width ?? AngledButtonMetrics.minWidth, maxHeight: .infinity, alignment: .top)
            .frame(width: width, height: AngledButtonMetrics.height)
            .background(background)
            .overlay(AngledButtonShape().stroke((isEnabled ? AppPalette.line : AppPalette.item).swiftUI, lineWidth: AngledButtonMetrics.borderStrokeWidth))
            .clipShape(AngledButtonShape())
            .contentShape(AngledButtonShape())
            .opacity(configuration.isPressed ? AngledButtonMetrics.pressedOpacity : 1)
    }

    /// Disabled, every fill goes dark: the window colour, with the border and label in the item grey
    /// (new-session-init.svg's Summon before a path is typed).
    @ViewBuilder private var background: some View {
        if !isEnabled {
            AppPalette.window.swiftUI
        } else {
            enabledBackground
        }
    }

    @ViewBuilder private var enabledBackground: some View {
        switch fill {
        case .gold:
            ZStack {
                AppPalette.questLogButtonGold.swiftUI
                angular(from: AppPalette.shadow.swiftUI.opacity(AngledButtonMetrics.goldGradientShadow), to: AppPalette.questLogButtonGold.swiftUI)
                    .opacity(AngledButtonMetrics.goldGradientOpacity)
            }
        case .plain:
            AppPalette.item.swiftUI
        case .danger:
            angular(from: AppPalette.questLogButtonDangerDeep.swiftUI, to: AppPalette.questLogButtonDanger.swiftUI)
        }
    }

    /// Starts pointing right from the button's left end and turns clockwise, so the top half lands near `end`.
    private func angular(from start: Color, to end: Color) -> some View {
        Canvas { context, size in
            context.translateBy(x: 0, y: size.height / 2)
            context.scaleBy(x: size.width / AngledButtonMetrics.gradientUnit, y: size.height / AngledButtonMetrics.gradientUnit)
            let span = AngledButtonMetrics.gradientSpan
            context.fill(
                Path(CGRect(x: -span / 2, y: -span / 2, width: span, height: span)),
                with: .conicGradient(Gradient(colors: [start, end]), center: .zero, angle: .zero)
            )
        }
    }
}

/// The design's angled-end button outline. The ends keep the 200 x 32 SVG's caps (11.944 deep, their
/// points 16.372 and 15.628 down), scaled to the button's height, and the straight runs stretch to its width.
struct AngledButtonShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cap: CGFloat = 11.944
        let w = rect.width, h = rect.height
        let sy = h / AngledButtonMetrics.designHeight
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(cap, 0))
        path.addLine(to: p(w - cap, 0))
        path.addCurve(to: p(w, 16.372), control1: p(w - 6.469, 0), control2: p(w, 12.651))
        path.addCurve(to: p(w - cap, 32), control1: p(w, 20.093), control2: p(w - 6.469, 32))
        path.addLine(to: p(cap, 32))
        path.addCurve(to: p(0, 15.628), control1: p(6.469, 32), control2: p(0, 19.349))
        path.addCurve(to: p(cap, 0), control1: p(0, 11.907), control2: p(6.469, 0))
        path.closeSubpath()
        return path
    }
}
