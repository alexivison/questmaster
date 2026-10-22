import Foundation

/// Keeps the app on the interaction-state rules (AGENTS.md, "Interaction states") by scanning app/Sources/App. A
/// source scan can't see everything; each rule is a pattern precise enough to have no false positives on the tree.
struct StateRulesScanTests {
    struct Rule {
        let name: String
        let pattern: String
        /// Paths under app/Sources/App the rule doesn't apply to: the token layer and the shared components.
        let allowedIn: [String]
    }

    /// A known break of a rule that a later change removes. The count must match exactly: a new break fails, and so
    /// does a fixed one until its entry goes, so the list only shrinks.
    struct Pending {
        let rule: String
        let file: String
        let count: Int
        let reason: String
    }

    static let tokenLayer = "SharedUI/Theme.swift"
    /// Render fixtures and self-tests, not views.
    static let exempt = ["Runtime/RenderPreview.swift", "Runtime/LogicSelfTests.swift"]

    static let rules = [
        Rule(
            name: "raw-colour",
            // Clear draws nothing, so it's allowed; black and white go through AppPalette.shadow, .light or .mask.
            // Shorthand colours (`.red`) count where a colour is taken (fill, stroke, color:, colors:, of: …), so a
            // `.white` enum case elsewhere (Quest Log art inks, NSFont.Weight.black) doesn't.
            pattern: #"NSColor\((hex|srgbRed|red|calibratedRed|deviceRed|displayP3Red|white|calibratedWhite|deviceWhite|genericGamma22White|cssHex:\s*")|\bColor\((red|white|hue|\.sRGB|\.displayP3|\.sRGBLinear)\b|#colorLiteral|\b(NSColor|Color)\.(black|white|red|green|blue|orange|yellow|pink|purple|gray|grey|brown|cyan|magenta|mint|teal|indigo|primary|secondary|accentColor|labelColor|secondaryLabelColor|tertiaryLabelColor|textColor|controlAccentColor|windowBackgroundColor|controlColor|system[A-Z]\w*)\b|\.foregroundStyle\(\.(primary|secondary|tertiary|tint)\)|\b(foregroundStyle|foregroundColor|fill|stroke|strokeBorder|background|backgroundColor|tint|border|shadow|color|colors|of)\s*[(:=][^\n]*?(?<!\w)\.(black|white|red|green|blue|orange|yellow|pink|purple|gray|grey|brown|cyan|magenta|mint|teal|indigo|primary|secondary|tertiary)\b"#,
            allowedIn: [tokenLayer]
        ),
        Rule(name: "state-colour", pattern: #"\bStateColor\b|\btextSelected\b"#, allowedIn: [tokenLayer]),
        Rule(name: "brass-on", pattern: #"\b(brassActive|ToggleLook)\b"#, allowedIn: [tokenLayer, "ActionBar/"]),
        Rule(
            name: "state-pick",
            pattern: #"(?i)\b\w*(select|highlight|focus|hover|active|checked)\w*\b[^?\n]*(?<!\?)\?(?!\?)\s[^:\n]*(AppPalette\.|\w\.color\b)"#,
            allowedIn: [tokenLayer]
        ),
        Rule(
            name: "dropdown",
            pattern: #"struct\s+\w*(Dropdown|SuggestionList|Suggestions)\s*(<[^>]*>)?\s*:\s*View\b|ForEach\([^\n]*[Ss]uggestion"#,
            allowedIn: ["SharedUI/FormControls.swift"]
        ),
        Rule(
            name: "field",
            pattern: #"\b(TextField|SecureField|TextEditor|NSSearchField|NSComboBox|NSTokenField)\(|\.textFieldStyle\(|NSTextField\((?!labelWithString)|\bfocusedControlBorder\("#,
            allowedIn: ["SharedUI/FormControls.swift", "SharedUI/FilterField.swift", "SharedUI/ModalPromptEditor.swift"]
        ),
    ]

    static let pending = [
        Pending(rule: "state-pick", file: "SharedUI/PillTabs.swift", count: 2, reason: "focus lift and disc fill: the shared tab (PR 2)"),
        Pending(rule: "state-pick", file: "SharedUI/SegmentedPicker.swift", count: 2, reason: "gold label and brass sprig: the shared tab (PR 2)"),
        Pending(rule: "brass-on", file: "SharedUI/SegmentedPicker.swift", count: 1, reason: "brass sprig on the selected tab: the shared tab (PR 2)"),
        Pending(rule: "state-pick", file: "SharedUI/FormControls.swift", count: 1, reason: "dropdown highlight text: the shared row (PR 2)"),
        Pending(rule: "state-pick", file: "Settings/SettingsSheet.swift", count: 1, reason: "compact picker border: the shared field (PR 2)"),
        Pending(rule: "state-pick", file: "Shell/ShellChromeControls.swift", count: 1, reason: "icon hover lift: the shared highlight (PR 2)"),
        Pending(rule: "state-pick", file: "Shell/ShellPaneContainers.swift", count: 1, reason: "dock frame focus: 2pt panel borders (PR 2)"),
        Pending(rule: "state-pick", file: "ActionBar/ActionBarFooterView.swift", count: 1, reason: "slot icon hover lift: the shared highlight (PR 2)"),
        Pending(rule: "state-pick", file: "Tracker/SwiftUITracker.swift", count: 1, reason: "selected plate title: the tracker highlight merge (PR 2)"),
        Pending(rule: "state-pick", file: "SharedUI/ItemCard.swift", count: 1, reason: "card hover = selected border: the artifact rows (PR 3)"),
        Pending(rule: "state-pick", file: "Dock/Artifact/ArtifactDockView.swift", count: 3, reason: "row title, icon and mark colours: the artifact rows (PR 3)"),
        Pending(rule: "state-pick", file: "SharedUI/ViewModifiers.swift", count: 1, reason: "brass filter focus: the shared field (PR 3)"),
        Pending(rule: "brass-on", file: "SharedUI/ViewModifiers.swift", count: 1, reason: "brass filter focus: the shared field (PR 3)"),
        Pending(rule: "field", file: "SharedUI/ViewModifiers.swift", count: 1, reason: "the artifact filter's own chrome: the shared field (PR 3)"),
        Pending(rule: "field", file: "Dock/Artifact/ArtifactDockView.swift", count: 1, reason: "the artifact filter's own chrome: the shared field (PR 3)"),
    ]

    static func run() {
        scannerCatchesEachRule()
        appSourcesFollowTheRules()
        print("StateRulesScanTests: all tests passed")
    }

    /// Each rule fires on a deliberate break, skips comments and spares the files it allows.
    private static func scannerCatchesEachRule() {
        let breaks = """
        let tint = NSColor(hex: 0x123456)
        let label = StateColor.textSelected
        let border = AppPalette.brassActive
        .foregroundStyle((isSelected ? AppPalette.item : AppPalette.panel).swiftUI)
        struct ProjectDropdown: View {
        TextField("Name", text: $name)
        // NSColor(hex: 0x123456) in a comment is fine
        """
        let found = violations(in: breaks, file: "Quest/Example.swift")
        for rule in rules {
            expect(found[rule.name] == 1, "\(rule.name) should fire once on its deliberate break, got \(found[rule.name] ?? 0)")
        }
        let rawColours = [
            ".foregroundStyle(.red)",
            "shape.fill(.orange)",
            ".stroke(.black, lineWidth: 1)",
            ".background(.white)",
            "shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 3)",
            "layer.backgroundColor = NSColor.white.cgColor",
            "LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)",
            "let light = tint.blended(withFraction: 0.5, of: .white) ?? tint",
            ".shadow(color: .black.opacity(0.35), radius: 18, y: 10)",
        ]
        for sample in rawColours {
            expect(violations(in: sample, file: "Quest/Example.swift")["raw-colour"] == 1, "raw-colour should catch \(sample)")
        }
        let notColours = [
            "Color.clear.frame(width: 0, height: 0)",
            ".fill((index == highlightedIndex ? AppPalette.item : .clear).swiftUI)",
            "shape.strokeBorder(AppPalette.shadow.swiftUI.opacity(0.1), lineWidth: 3)",
            "(.white, 0.43, \"M463.659 63.502\")",
            "let font = NSFont.systemFont(ofSize: 12, weight: .black)",
        ]
        for sample in notColours {
            expect(violations(in: sample, file: "Quest/Example.swift")["raw-colour"] == nil, "raw-colour should allow \(sample)")
        }
        expect(violations(in: "let tint = NSColor(hex: 0x123456)", file: tokenLayer).isEmpty, "the token layer may name colours")
        expect(violations(in: "let border = AppPalette.brassActive", file: "ActionBar/Slot.swift").isEmpty, "the action bar may use brass")
        let clean = "let look = RowLook.pick(highlighted: true, areaFocused: true)\nlet fill = look.fill ?? nil"
        expect(violations(in: clean, file: "Quest/Example.swift").isEmpty, "asking for a state look is no break")
    }

    private static func appSourcesFollowTheRules() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        guard let files = FileManager.default.enumerator(atPath: root.path)?.compactMap({ $0 as? String }) else {
            fatalError("could not list \(root.path)")
        }
        var found: [String: Int] = [:]
        for file in files where file.hasSuffix(".swift") && !exempt.contains(file) {
            guard let source = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8) else {
                fatalError("could not read \(file)")
            }
            for (rule, count) in violations(in: source, file: file) {
                found["\(rule) \(file)"] = count
            }
        }
        var expected: [String: Int] = [:]
        for entry in pending {
            expected["\(entry.rule) \(entry.file)"] = entry.count
        }
        let failures = Set(found.keys).union(expected.keys).sorted().compactMap { key -> String? in
            let (actual, allowed) = (found[key] ?? 0, expected[key] ?? 0)
            if actual > allowed { return "\(key): \(actual - allowed) new break(s) of the interaction-state rules" }
            if actual < allowed { return "\(key): fixed; lower its pending count to \(actual)" }
            return nil
        }
        expect(failures.isEmpty, "interaction-state rules (AGENTS.md):\n" + failures.joined(separator: "\n"))
    }

    /// Rule name to the number of lines that break it. Comment lines don't count.
    static func violations(in source: String, file: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        let lines = source.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        for rule in rules where !rule.allowedIn.contains(where: { file.hasPrefix($0) }) {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else {
                fatalError("bad pattern for \(rule.name)")
            }
            let hits = lines.filter { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.count
            if hits > 0 {
                counts[rule.name] = hits
            }
        }
        return counts
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fatalError(message)
        }
    }
}
