import AppKit
import MarkdownUI
import QuestmasterCore

/// The user's Ghostty `font-family`, resolved once on first use from the config files Ghostty itself
/// loads (ghostty_config_get cannot return this repeatable key). nil means fall back to the system mono.
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

    /// `family`'s face at this size, weight and style, or nil when the family has no such face. CoreText
    /// substitutes the nearest face instead of failing (Monaco's semibold is Regular, Menlo's is Bold), so the
    /// substitute's traits are checked before it is returned.
    static func face(family: String, size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont? {
        var descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        if italic {
            descriptor = descriptor.withSymbolicTraits(.italic)
        }
        guard let font = NSFont(descriptor: descriptor, size: size), matches(font, weight: weight, italic: italic) else {
            return nil
        }
        return font
    }

    /// Whether `font` has exactly the requested weight and style.
    static func matches(_ font: NSFont, weight: NSFont.Weight, italic: Bool) -> Bool {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let resolvedWeight = (traits?[.weight] as? CGFloat) ?? 0
        let isItalic = font.fontDescriptor.symbolicTraits.contains(.italic)
        return abs(resolvedWeight - weight.rawValue) < weightTolerance && isItalic == italic
    }

    /// Weight traits come back as floats (semibold reads 0.3), so exact equality would miss real matches.
    private static let weightTolerance: CGFloat = 0.01

    /// The faces the Markdown themes use: regular text, semibold headings and italic emphasis.
    private static let markdownFaces: [(weight: NSFont.Weight, italic: Bool)] = [
        (.regular, false),
        (.semibold, false),
        (.regular, true),
    ]

    /// The Markdown family for the user's Ghostty family.
    static let markdownFamily: FontProperties.Family = markdownFamily(for: resolved)

    /// `family` when it has every face the Markdown themes use, else the system mono.
    // ponytail: whole family or nothing. A partial family (Menlo, no semibold) renders Markdown in system mono; per-style fallback in the Markdown theme if that matters.
    static func markdownFamily(for family: String?) -> FontProperties.Family {
        guard let family,
              markdownFaces.allSatisfy({ face(family: family, size: NSFont.systemFontSize, weight: $0.weight, italic: $0.italic) != nil })
        else {
            return .system(.monospaced)
        }
        return .custom(family)
    }
}
