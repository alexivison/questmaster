import AppKit
import QuestmasterCore

/// The user's Ghostty `font-family`, resolved once on first use from the config files Ghostty itself
/// loads (ghostty_config_get cannot return this repeatable key). nil means fall back to the system fonts.
enum GhosttyFontFamily {
    static let resolved: String? = {
        let family = familyFromConfigFiles()
        trace(family)
        return family
    }()

    /// The family at Questmaster's own size and weight, or nil when it is unset or not installed.
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

    /// Ghostty reads the XDG config first and the app-support config after it, so the later file wins.
    private static func familyFromConfigFiles() -> String? {
        let xdgHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? NSHomeDirectory() + "/.config"
        let appSupport = NSHomeDirectory() + "/Library/Application Support/com.mitchellh.ghostty"
        let text = [xdgHome + "/ghostty", appSupport]
            .flatMap { directory in ["config", "config.ghostty"].map { "\(directory)/\($0)" } }
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .joined(separator: "\n")
        return GhosttyConfigParser.primaryFontFamily(in: text)
    }

    private static func trace(_ family: String?) {
        guard ProcessInfo.processInfo.environment["QM_TRACE_FONT"] != nil else {
            return
        }
        print("Ghostty font-family: \(family ?? "<none>")")
    }
}
