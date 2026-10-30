import Foundation

#if DEBUG
/// Traces the class avatar's flights to `~/.questmaster-state/avatar-flight.log`, one line per step, so a run shows where a spell
/// stops. Debug builds only: a release build compiles the calls to nothing, and their messages are never built.
enum AvatarFlightLog {
    private static let url = URL(fileURLWithPath: NSString(string: "~/.questmaster-state/avatar-flight.log").expandingTildeInPath)
    /// The self-tests and the render previews drive the same code, so they leave the live app's trace alone.
    private static let isLiveApp = !ProcessInfo.processInfo.arguments.contains { $0 == "--run-logic-tests" || $0 == "--render-preview" }

    static func write(_ message: @autoclosure () -> String) {
        guard isLiveApp else {
            return
        }
        let line = Data("\(Date().timeIntervalSince1970) \(message())\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
#else
enum AvatarFlightLog {
    static func write(_ message: @autoclosure () -> String) {}
}
#endif
