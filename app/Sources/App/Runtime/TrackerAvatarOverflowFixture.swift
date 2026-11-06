#if DEBUG
import AppKit
import ImageIO
import QuestmasterCore

/// A throwaway sprite class for checking a pose that reaches above the fixed idle-sized slot.
@MainActor
enum TrackerAvatarOverflowFixture {
    static let panelOverlap = Space.item * 2
    static var slotTop: CGFloat { SelectedSessionPanel.canvasSize.height - panelOverlap }
    static var canvas: CGSize {
        CGSize(width: TrackerAvatarMetrics.slotWidth, height: SelectedSessionPanel.canvasSize.height + TrackerAvatarMetrics.slotHeight - panelOverlap)
    }

    struct Fixture {
        let sprites: TrackerAvatarSprites
        let folder: URL
    }

    static func make() throws -> Fixture {
        guard let source = AppSymbolStyle.resourceBundle().url(
            forResource: "animation", withExtension: "json", subdirectory: "Sprites/wizard"
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("avatar-tall-pose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            let data = try Data(contentsOf: source)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var poses = json["poses"] as? [String: Any],
                  var idle = poses["01-idle"] as? [String: Any],
                  var callingOut = poses["11-calling-out"] as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }

            idle["foot_row"] = 159
            poses["01-idle"] = idle
            callingOut["foot_row"] = 185
            callingOut["body_column"] = 40
            callingOut["loop"] = ["character": [[1, 0.2]]]
            for key in ["enter", "finish", "once", "front", "behind", "bubble", "strike_frame"] {
                callingOut.removeValue(forKey: key)
            }
            poses["11-calling-out"] = callingOut
            json["poses"] = poses
            try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("animation.json"))

            try writeFrame(color: CGColor(red: 0.1, green: 0.65, blue: 0.2, alpha: 1), to: folder.appendingPathComponent("01-idle-f1.png"))
            try writeCallingOutFrame(to: folder.appendingPathComponent("11-calling-out-f1.png"))

            guard let sprites = TrackerAvatarSprites(classID: "synthetic-tall-pose", folder: folder) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return Fixture(sprites: sprites, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private static func writeFrame(color: CGColor, to url: URL) throws {
        let context = try makeContext()
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 200))
        try write(context, to: url)
    }

    private static func writeCallingOutFrame(to url: URL) throws {
        let context = try makeContext()
        context.clear(CGRect(x: 0, y: 0, width: 80, height: 200))
        context.setShouldAntialias(false)

        func fill(_ rect: CGRect, color: CGColor) {
            context.setFillColor(color)
            context.fill(rect)
        }

        let leather = CGColor(red: 0.42, green: 0.18, blue: 0.12, alpha: 1)
        let cloth = CGColor(red: 0.62, green: 0.23, blue: 0.12, alpha: 1)
        let skin = CGColor(red: 0.8, green: 0.51, blue: 0.34, alpha: 1)
        let steel = CGColor(red: 0.58, green: 0.66, blue: 0.72, alpha: 1)
        let axeMark = CGColor(red: 0.95, green: 0.04, blue: 0.06, alpha: 1)

        fill(CGRect(x: 25, y: 12, width: 13, height: 56), color: leather)
        fill(CGRect(x: 43, y: 12, width: 13, height: 56), color: leather)
        fill(CGRect(x: 20, y: 64, width: 42, height: 59), color: cloth)
        fill(CGRect(x: 17, y: 72, width: 10, height: 43), color: skin)
        fill(CGRect(x: 55, y: 86, width: 10, height: 38), color: skin)
        fill(CGRect(x: 27, y: 123, width: 28, height: 24), color: skin)
        fill(CGRect(x: 23, y: 148, width: 38, height: 7), color: leather)
        fill(CGRect(x: 61, y: 98, width: 5, height: 99), color: leather)
        fill(CGRect(x: 49, y: 174, width: 29, height: 26), color: steel)
        fill(CGRect(x: 49, y: 188, width: 29, height: 12), color: axeMark)
        try write(context, to: url)
    }

    private static func makeContext() throws -> CGContext {
        guard let context = CGContext(
            data: nil,
            width: 80,
            height: 200,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return context
    }

    private static func write(_ context: CGContext, to url: URL) throws {
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
#endif
