import Foundation

/// The "you are here" dot on the attached session's plate. The attached session is the one open in the terminal, not
/// the keyboard cursor or the pointer's row, and the dot never moves, reflows or renumbers a plate.
public enum TrackerAttachedDot {
    /// Whether the plate of `plateID` carries the dot. A plate carries it for its own session, and a master that has
    /// collapsed its workers carries it for any of them (`collapsedWorkerIDs`: the workers the plate shows only as
    /// circles), because a collapsed worker has no plate of its own. A shell has no plate, an id the tracker doesn't
    /// list matches no plate, and with nothing attached no plate carries the dot.
    public static func isShown(onPlate plateID: String, collapsedWorkerIDs: [String], attachedID: String?) -> Bool {
        guard let attachedID = cleanSessionID(attachedID) else {
            return false
        }
        return attachedID == plateID || collapsedWorkerIDs.contains(attachedID)
    }
}
