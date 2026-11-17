import QuestmasterCore
import SwiftUI

/// The brass inner glow of an "on" look (`OnLook`): a band `band` wide inside `shape`'s edge, clipped to it. A border drawn
/// over it covers its outer part, so the band shows only inside. A toggle that is on and a dock title plate with its
/// refresh running both draw it.
struct OnLookGlow: View {
    let look: OnLook
    let shape: AnyShape
    let band: CGFloat

    var body: some View {
        if look.glowOpacity > 0 {
            shape
                .stroke(look.glow.color.swiftUI.opacity(look.glowOpacity), lineWidth: 2 * band)
                .clipShape(shape)
        }
    }
}

/// The working spinner turning round an "on" look's outline while it spins (`OnLook.spins`). Nothing is drawn otherwise.
struct OnLookSpinner: View {
    let look: OnLook
    let outline: SpinnerOutline
    let stroke: CGFloat

    var body: some View {
        if look.spins {
            SpinnerRingView(stroke: stroke, outline: outline)
        }
    }
}
