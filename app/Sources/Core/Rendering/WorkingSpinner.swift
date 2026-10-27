import Foundation

/// The working spinner's timing: a third of a ring turning once every `period`. The tracker's portrait ring and the
/// dock's refresh mark draw the same spinner (`SpinnerRing`), and a refresh shows it for at least one turn.
public enum WorkingSpinner {
    public static let period: TimeInterval = 1.2
    /// How much of the ring the spinner's arc covers, tail to head.
    public static let arc: Double = 1.0 / 3
}
