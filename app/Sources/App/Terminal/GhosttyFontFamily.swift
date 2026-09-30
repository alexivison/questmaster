import AppKit
import GhosttyKit
import QuestmasterCore

/// The user's Ghostty `font-family`, resolved once on first use: ghostty_config_get on a fresh config
/// first, then the config files Ghostty itself loads. nil means fall back to the system fonts.
enum GhosttyFontFamily {
    static let resolved: String? = {
        if let family = familyFromConfigAPI() {
            trace("ghostty_config_get", family)
            return family
        }
        let family = familyFromConfigFiles()
        trace("config files", family)
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

    private static func familyFromConfigAPI() -> String? {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0, let config = ghostty_config_new() else {
            return nil
        }
        defer { ghostty_config_free(config) }
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        var value: UnsafePointer<CChar>?
        let key = "font-family"
        guard ghostty_config_get(config, &value, key, UInt(key.utf8.count)), let value else {
            return nil
        }
        let family = String(cString: value)
        return family.isEmpty ? nil : family
    }

    /// Ghostty reads the XDG config first and the app-support config after it, so the later file wins.
    private static func familyFromConfigFiles() -> String? {
        let xdgHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? NSHomeDirectory() + "/.config"
        var paths = ["config", "config.ghostty"].map { "\(xdgHome)/ghostty/\($0)" }
        if let openPath = configOpenPath() {
            paths.append(openPath)
        }
        let text = paths
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .joined(separator: "\n")
        return GhosttyConfigParser.primaryFontFamily(in: text)
    }

    private static func configOpenPath() -> String? {
        let path = ghostty_config_open_path()
        defer { ghostty_string_free(path) }
        guard let pointer = path.ptr, path.len > 0 else {
            return nil
        }
        return String(
            decoding: UnsafeBufferPointer(start: pointer, count: Int(path.len)).map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
    }

    private static func trace(_ source: String, _ family: String?) {
        guard ProcessInfo.processInfo.environment["QM_TRACE_FONT"] != nil else {
            return
        }
        print("Ghostty font-family via \(source): \(family ?? "<none>")")
    }
}
