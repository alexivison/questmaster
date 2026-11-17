import Foundation

/// The keyboard cursor's menu pointer: an arrowhead drawn outside a card's or a row's leading edge (`RowLook.pointer`).
/// The App draws each outline as a path, antialiased, with a round-joined stroke (`MenuPointerView`). The geometry is
/// whole points in Int, and the outlines are points in the frame, so the App makes the one conversion to CGFloat.
public enum MenuPointer {
    /// The frame in whole points: the footprint of the earlier 6 by 7 pixel arrow at 2pt per pixel.
    public static let width = 12
    public static let height = 14

    /// The arrow's shape. `arrowhead` ships; the other two are kept so the user can pick (`RenderPreview` draws all three).
    public enum Shape: CaseIterable, Sendable {
        /// A solid right-pointing triangle; its corners are softened by the round join of the stroke.
        case arrowhead
        /// An open line chevron, stroked only.
        case chevron
        /// A solid triangle with a shallow notch cut into its back edge.
        case notched
    }

    /// A point in the frame, in points, with y pointing down.
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(_ x: Double, _ y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The outline's points in the frame. The points sit half a 1.5pt stroke inside the frame's edges (0.75pt), so the
    /// stroke's ink stays inside it.
    public static func outline(_ shape: Shape) -> [Point] {
        switch shape {
        case .arrowhead:
            return [Point(1.25, 1.25), Point(8.75, 7), Point(1.25, 12.75)]
        case .chevron:
            return [Point(2.25, 1.25), Point(8.75, 7), Point(2.25, 12.75)]
        case .notched:
            return [Point(1.25, 1.25), Point(8.75, 7), Point(1.25, 12.75), Point(4.25, 7)]
        }
    }

    /// Whether the shape is a closed, filled outline. A chevron is an open line, stroked only.
    public static func isFilled(_ shape: Shape) -> Bool {
        shape != .chevron
    }

    /// The frame's leading edge, relative to a card's leading edge: the frame's trailing edge sits `gap` points outside it.
    public static func leadingOffset(gap: Int) -> Int {
        -(gap + width)
    }

    /// The frame's top, relative to a row's top: centred on the row, on whole points. The row is at least as tall as the frame.
    public static func topOffset(rowHeight: Int) -> Int {
        (rowHeight - height) / 2
    }
}
