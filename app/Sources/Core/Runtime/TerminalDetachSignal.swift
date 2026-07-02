/// Marker emitted by the tmux startup script as an OSC 0 title when
/// `tmux attach-session` returns.
public enum TerminalDetachSignal {
    public static let markerTitle = "questmaster-detached"

    public static func isDetachMarker(_ title: String) -> Bool {
        title == markerTitle
    }
}
