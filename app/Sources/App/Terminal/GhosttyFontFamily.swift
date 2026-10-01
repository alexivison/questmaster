import AppKit
import QuestmasterCore

/// The user's Ghostty `font-family`, resolved once on first use from the config files Ghostty itself
/// loads (ghostty_config_get cannot return this repeatable key). nil means fall back to the system fonts.
enum GhosttyFontFamily {
    static let resolved: String? = {
        let xdgHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        let directories = [
            xdgHome + "/ghostty",
            NSHomeDirectory() + "/Library/Application Support/com.mitchellh.ghostty",
        ]
        let families = GhosttyConfigParser.fontFamilies(inDirectories: directories) {
            try? String(contentsOfFile: $0, encoding: .utf8)
        }
        return GhosttyConfigParser.firstInstalled(of: families) {
            NSFontManager.shared.availableMembers(ofFontFamily: $0)?.isEmpty == false
        }
    }()

    /// The family at Questmaster's own size and weight, or nil when none is set or installed.
    static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        guard let family = resolved else {
            return nil
        }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        return NSFont(descriptor: descriptor, size: size)
    }
}
