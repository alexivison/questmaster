import AppKit
import QuestmasterCore
import SwiftUI

/// The bundled class portraits and familiars, loaded once. They are 3x rasters of the discs they fill, so they stay
/// sharp on a Retina display.
enum SessionPortraitImages {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for portrait: SessionPortrait) -> NSImage? {
        let name = portrait.resourceName as NSString
        if let cached = cache.object(forKey: name) {
            return cached
        }
        guard let url = AppSymbolStyle.resourceBundle().url(forResource: portrait.resourceName, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        cache.setObject(image, forKey: name)
        return image
    }
}

extension GraphicsContext {
    /// A portrait over `disc`, clipped to its circle. The disc's own fill is drawn first, so the image's transparent
    /// edge shows it.
    func drawPortrait(_ portrait: SessionPortrait, in disc: Path) {
        guard let image = SessionPortraitImages.image(for: portrait) else {
            return
        }
        drawLayer { clipped in
            clipped.clip(to: disc)
            clipped.draw(Image(nsImage: image).interpolation(.high), in: disc.boundingRect)
        }
    }
}

extension TrackerPlateShadow {
    /// The portrait discs' inner shadow, as Class & Title.svg and Portrait.svg draw it: 3 deep, blurred by half a point.
    static let sheetPortrait = TrackerPlateShadow(depth: 3, blur: 0.5, opacity: 0.2)
}

enum SessionPortraitMetrics {
    /// The sheets' portrait disc, as Class & Title.svg draws it: as tall as the row it starts, 5 taller than the title field.
    static let sheetDiameter = ControlHeight.bar
}

/// A portrait disc in a sheet, as Class & Title.svg draws it: the panel's fill, the portrait, its inner shadow and a 1pt
/// `line` border.
struct SessionPortraitDisc: View {
    let portrait: SessionPortrait

    var body: some View {
        Canvas { context, size in
            let frame = CGRect(origin: .zero, size: size)
            let disc = Path(ellipseIn: frame)
            context.fill(disc, with: .color(AppPalette.panel.swiftUI))
            context.drawPortrait(portrait, in: disc)
            context.fillInnerShadow(disc, .sheetPortrait)
            let border = Token.Size.divider
            context.stroke(Path(ellipseIn: frame.insetBy(dx: border / 2, dy: border / 2)), with: .color(AppPalette.line.swiftUI), lineWidth: border)
        }
        .frame(width: SessionPortraitMetrics.sheetDiameter, height: SessionPortraitMetrics.sheetDiameter)
    }
}

/// The title row of New Session and Edit Session, as Class & Title.svg draws it: the portrait disc, 10 before the title
/// field, which is 35 high and top-aligned with the disc. A click on an editable portrait cycles the class; a
/// read-only one (a worker's familiar) ignores it. With no portrait the row is the field alone.
///
/// An editable portrait is one accessibility button, whose default action cycles, as a `PillTab` is; a read-only one
/// is an image with no action.
struct SessionTitleRow<Field: View>: View {
    let portrait: SessionPortrait?
    let portraitLabel: String
    /// Nil makes the portrait read-only.
    var onPortraitClick: (() -> Void)?
    @ViewBuilder var field: () -> Field

    var body: some View {
        HStack(alignment: .top, spacing: Space.item) {
            if let portrait {
                portraitView(portrait)
            }
            field()
        }
    }

    @ViewBuilder
    private func portraitView(_ portrait: SessionPortrait) -> some View {
        let disc = SessionPortraitDisc(portrait: portrait)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(portraitLabel)
        if let onPortraitClick {
            disc
                .contentShape(Circle())
                .onTapGesture(perform: onPortraitClick)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, onPortraitClick)
        } else {
            disc
                .accessibilityAddTraits(.isImage)
        }
    }
}
