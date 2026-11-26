import SwiftUI

/// A vertical list whose bottom edge fades while there are more rows below it.
struct ListScrollView<Content: View>: View {
    var indicators: ScrollIndicatorVisibility = .hidden
    /// The Worker Log reserves this band under its header for rows scrolling out of the top.
    var topFadeHeight: CGFloat = 0
    @ViewBuilder var content: () -> Content

    @State private var moreBelow = false

    var body: some View {
        ScrollView {
            content()
                .background(ScrollerHider())
                .background(ScrollOverflowObserver(axis: .vertical) { moreBelow = $0.after })
        }
        .scrollIndicators(indicators)
        .mask {
            let opaque = AppPalette.mask.swiftUI
            VStack(spacing: 0) {
                if topFadeHeight > 0 {
                    LinearGradient(colors: [.clear, opaque], startPoint: .top, endPoint: .bottom)
                        .frame(height: topFadeHeight)
                }
                opaque
                if moreBelow {
                    LinearGradient(colors: [opaque, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: Space.item)
                }
            }
        }
    }
}
