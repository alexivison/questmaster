import AppKit

enum AppPalette {
    struct NeutralRamp {
        let window: NSColor
        let panelAlt: NSColor
        let panel: NSColor
        let questListColumn: NSColor
        let questViewerBackground: NSColor
        let terminal: NSColor
        let selection: NSColor
        let hoverBackground: NSColor
        let controlFill: NSColor
        let line: NSColor
        let lineSoft: NSColor
        let lineSoftSubtle: NSColor
        let hoverBorder: NSColor
        let connectorLine: NSColor
        let activeControlBorder: NSColor
    }

    private struct RGB {
        let red: Int
        let green: Int
        let blue: Int

        init(red: Int, green: Int, blue: Int) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init?(color: NSColor) {
            guard let components = color.rgbComponents8 else {
                return nil
            }
            self.init(red: components.red, green: components.green, blue: components.blue)
        }

        var color: NSColor {
            NSColor(hex: UInt32(red << 16 | green << 8 | blue))
        }

        func offset(red redOffset: Int, green greenOffset: Int, blue blueOffset: Int) -> RGB {
            RGB(
                red: Self.clamp(red + redOffset),
                green: Self.clamp(green + greenOffset),
                blue: Self.clamp(blue + blueOffset)
            )
        }

        private static func clamp(_ value: Int) -> Int {
            min(255, max(0, value))
        }
    }

    private static let defaultNeutralBase = RGB(red: 0x0f, green: 0x11, blue: 0x15)
    private static let defaultNeutralRamp = neutralRamp(baseRGB: defaultNeutralBase)

    static var window = defaultNeutralRamp.window
    static var panelAlt = defaultNeutralRamp.panelAlt
    static var panel = defaultNeutralRamp.panel
    static var questListColumn = defaultNeutralRamp.questListColumn
    static var questViewerBackground = defaultNeutralRamp.questViewerBackground
    static var terminal = defaultNeutralRamp.terminal
    static var selection = defaultNeutralRamp.selection
    static var hoverBackground = defaultNeutralRamp.hoverBackground
    static var controlFill = defaultNeutralRamp.controlFill
    static var line = defaultNeutralRamp.line
    static var lineSoft = defaultNeutralRamp.lineSoft
    static var lineSoftSubtle = defaultNeutralRamp.lineSoftSubtle
    static var hoverBorder = defaultNeutralRamp.hoverBorder
    static var connectorLine = defaultNeutralRamp.connectorLine
    static var activeControlBorder = defaultNeutralRamp.activeControlBorder

    static let terminalForeground = NSColor(calibratedWhite: 0.88, alpha: 1)
    static let activeText = NSColor(hex: 0xe6edf3)
    static let text = NSColor(hex: 0xd8dee9)
    static let bright = NSColor(hex: 0xf2f5f8)
    static let muted = NSColor(hex: 0x8b949e)
    static let dim = NSColor(hex: 0x68717d)
    static let slate = NSColor(hex: 0x7f93b0)

    // Ported from internal/palette/palette.go and TUI ANSI semantics.
    static let added = NSColor(hex: 0x7ee787)
    static let deleted = NSColor(hex: 0xff7b72)
    static let warn = NSColor(hex: 0xd29922)
    static let accent = NSColor(hex: 0x58a6ff)
    static let activeSideCardBorder = accent.withAlphaComponent(0.4)
    static let masterRole = NSColor(hex: 0xf2cc60)
    static let workerRole = NSColor(hex: 0xbc8cff)
    static let standaloneRole = added
    static let tmuxRole = accent
    static let orphanRole = muted
    static let claude = NSColor(hex: 0xcc785c)
    static let codex = NSColor(hex: 0x1a73e8)
    static let pi = NSColor(hex: 0xa371f7)
    static let omp = NSColor(hex: 0x2dd4bf)
    static let trackerWorking = NSColor(hex: 0xd9a441)
    static let trackerBlocked = NSColor(hex: 0xe5534b)
    static let trackerDone = NSColor(hex: 0x57ab5a)
    static let trackerIdle = NSColor(hex: 0x6f757c)
    static let trackerNeedsInput = NSColor(hex: 0xe8b34a)
    static let trackerError = NSColor(hex: 0xe8743b)

    static let repoFallbacks = [
        NSColor(hex: 0x58a6ff),
        NSColor(hex: 0xd29922),
        NSColor(hex: 0xbc8cff),
        NSColor(hex: 0x2dd4bf),
        NSColor(hex: 0xf778ba),
    ]

    static let displayFallbacks = [
        NSColor(hex: 0x4d9bf0),
        NSColor(hex: 0x57ab5a),
        NSColor(hex: 0xd9a441),
        NSColor(hex: 0xc578dd),
        NSColor(hex: 0x4fb6c4),
        NSColor(hex: 0xe5534b),
        NSColor(hex: 0xe0883b),
        NSColor(hex: 0xd7b13d),
        NSColor(hex: 0x8cc265),
        NSColor(hex: 0x2bb8a3),
        NSColor(hex: 0x4cb3e6),
        NSColor(hex: 0x7a7af0),
        NSColor(hex: 0xb886e6),
        NSColor(hex: 0xe57ab0),
    ]

    static let displayColorNames: [String: NSColor] = [
        "blue": NSColor(hex: 0x4d9bf0),
        "green": NSColor(hex: 0x57ab5a),
        "yellow": NSColor(hex: 0xd9a441),
        "magenta": NSColor(hex: 0xc578dd),
        "cyan": NSColor(hex: 0x4fb6c4),
        "red": NSColor(hex: 0xe5534b),
        "orange": NSColor(hex: 0xe0883b),
        "gold": NSColor(hex: 0xd7b13d),
        "lime": NSColor(hex: 0x8cc265),
        "teal": NSColor(hex: 0x2bb8a3),
        "sky": NSColor(hex: 0x4cb3e6),
        "indigo": NSColor(hex: 0x7a7af0),
        "violet": NSColor(hex: 0xb886e6),
        "pink": NSColor(hex: 0xe57ab0),
    ]

    static func agent(_ name: String) -> NSColor {
        switch name.lowercased() {
        case "claude":
            return claude
        case "codex":
            return codex
        case "pi":
            return pi
        case "omp":
            return omp
        default:
            return muted
        }
    }

    static func role(_ role: String) -> NSColor {
        switch role.lowercased() {
        case "master", "primary":
            return masterRole
        case "worker":
            return workerRole
        case "tmux":
            return tmuxRole
        case "orphan":
            return orphanRole
        default:
            return standaloneRole
        }
    }

    static func status(_ state: String) -> NSColor {
        switch state.lowercased() {
        case "working", "starting", "checking":
            return masterRole
        case "blocked", "error", "failed", "fail":
            return deleted
        case "done", "pass", "passed", "ok":
            return added
        case "stopped":
            return dim
        default:
            return muted
        }
    }

    static func questStatus(_ status: String) -> NSColor {
        switch status.lowercased() {
        case "active":
            return accent
        case "done":
            return added
        default:
            return warn
        }
    }

    static func displayColor(_ value: String) -> NSColor? {
        if let color = NSColor(cssHex: value) {
            return color
        }
        return displayColorNames[value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    static func repo(_ value: String, index: Int) -> NSColor {
        if let color = displayColor(value) {
            return color
        }
        return repoFallbacks[index % repoFallbacks.count]
    }

    static func applyNeutralBase(_ base: NSColor) {
        let ramp = neutralRamp(base: base)
        window = ramp.window
        panelAlt = ramp.panelAlt
        panel = ramp.panel
        questListColumn = ramp.questListColumn
        questViewerBackground = ramp.questViewerBackground
        terminal = ramp.terminal
        selection = ramp.selection
        hoverBackground = ramp.hoverBackground
        controlFill = ramp.controlFill
        line = ramp.line
        lineSoft = ramp.lineSoft
        lineSoftSubtle = ramp.lineSoftSubtle
        hoverBorder = ramp.hoverBorder
        connectorLine = ramp.connectorLine
        activeControlBorder = ramp.activeControlBorder
    }

    static func neutralRamp(base: NSColor) -> NeutralRamp {
        neutralRamp(baseRGB: RGB(color: base) ?? defaultNeutralBase)
    }

    static func isDarkNeutralBase(_ color: NSColor) -> Bool {
        guard let rgb = RGB(color: color) else {
            return false
        }
        let red = 0.299 * Double(rgb.red)
        let green = 0.587 * Double(rgb.green)
        let blue = 0.114 * Double(rgb.blue)
        let luminance = (red + green + blue) / 255
        return luminance < 0.5
    }

    private static func neutralRamp(baseRGB base: RGB) -> NeutralRamp {
        NeutralRamp(
            window: base.color,
            panelAlt: base.offset(red: 2, green: 3, blue: 4).color,
            panel: base.offset(red: 7, green: 8, blue: 8).color,
            questListColumn: base.offset(red: 7, green: 8, blue: 8).color,
            questViewerBackground: base.offset(red: 0, green: 2, blue: 1).color,
            terminal: base.color,
            selection: base.offset(red: 30, green: 34, blue: 38).color,
            hoverBackground: base.offset(red: 18, green: 21, blue: 24).color,
            controlFill: base.offset(red: 18, green: 21, blue: 24).color,
            line: base.offset(red: 28, green: 32, blue: 36).color,
            lineSoft: base.offset(red: 20, green: 23, blue: 25).color,
            lineSoftSubtle: base.offset(red: 13, green: 17, blue: 19).color,
            hoverBorder: base.offset(red: 48, green: 54, blue: 59).color,
            connectorLine: base.offset(red: 48, green: 54, blue: 59).color,
            activeControlBorder: base.offset(red: 33, green: 37, blue: 40).color
        )
    }
}

enum AppFonts {
    static let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let monoBold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    static let terminal = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let body = NSFont.systemFont(ofSize: 13)
    static let bodyBold = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let title = NSFont.systemFont(ofSize: 20, weight: .semibold)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    convenience init?(cssHex value: String) {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") {
            raw.removeFirst()
        }
        guard raw.count == 6, let hex = UInt32(raw, radix: 16) else {
            return nil
        }
        self.init(hex: hex)
    }

    var rgbHex: UInt32? {
        guard let components = rgbComponents8 else {
            return nil
        }
        return UInt32(components.red << 16 | components.green << 8 | components.blue)
    }

    fileprivate var rgbComponents8: (red: Int, green: Int, blue: Int)? {
        let rgbColor: NSColor
        if colorSpace.colorSpaceModel == .rgb {
            rgbColor = self
        } else if let converted = usingColorSpace(.sRGB) ?? usingColorSpace(.deviceRGB) {
            rgbColor = converted
        } else {
            return nil
        }
        return (
            red: Self.channel8(rgbColor.redComponent),
            green: Self.channel8(rgbColor.greenComponent),
            blue: Self.channel8(rgbColor.blueComponent)
        )
    }

    private static func channel8(_ value: CGFloat) -> Int {
        min(255, max(0, Int((value * 255).rounded())))
    }
}
