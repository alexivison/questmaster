import QuestmasterCore

/// Owns the dock's app-wide state (`DockState`) for the shell's renderer and the app's dock commands. Nothing here
/// depends on the viewed session.
@MainActor
final class DockCoordinator {
    var state = DockState.initial
}
