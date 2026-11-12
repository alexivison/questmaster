import Foundation
import QuestmasterCore

enum GhosttyConfigFiles {
    static var searchDirectories: [String] {
        let xdgHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        return [
            xdgHome + "/ghostty",
            NSHomeDirectory() + "/Library/Application Support/com.mitchellh.ghostty",
        ]
    }

    static func loadedPaths() -> [String] {
        GhosttyConfigParser.loadedFiles(inDirectories: searchDirectories) {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
    }
}
