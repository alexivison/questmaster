#if DEBUG
import AppKit
import ImageIO
import QuestmasterCore
import SwiftUI
import UniformTypeIdentifiers

/// Dev-only: renders the portrait ring's animated states (filling, the overrun pulse, the spinner and the finish flash)
/// on every portrait size, and a GIF of a master with collapsed workers casting. It captures Core Animation's
/// presentation layers, which the plain offscreen snapshot cannot see. `--render-ring-preview <dir>`.
@MainActor
enum RingPreview {
    private static let canvas = CGSize(width: 340, height: 330)
    private static let settle: TimeInterval = 0.8

    static func runIfRequested() -> Bool {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--render-ring-preview") else { return false }
        let dir = CommandLine.arguments.count > flagIndex + 1 ? CommandLine.arguments[flagIndex + 1] : NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for scale: CGFloat in [1, 4] {
            still(.filling, scale: scale, to: "\(dir)/ring-filling-\(Int(scale))x.png")
            still(.overrun, scale: scale, to: "\(dir)/ring-overrun-\(Int(scale))x.png")
            still(.spinning, scale: scale, to: "\(dir)/ring-spinning-\(Int(scale))x.png")
            still(.flash, scale: scale, to: "\(dir)/ring-flash-\(Int(scale))x.png")
        }
        gif(to: "\(dir)/ring-master-collapsed-2x.gif")
        let exitMoments: [(name: String, time: TimeInterval)] = [
            ("working", 1.0), ("exit-sweep", 1.5 + 0.12), ("exit-flash", 1.5 + 0.35), ("exit-fade", 1.5 + 0.75), ("after", 3.2),
        ]
        for scale: CGFloat in [1, 4] {
            let frames = exitRun(scale: scale, times: exitMoments.map(\.time))
            for (moment, frame) in zip(exitMoments, frames) {
                write(frame, to: "\(dir)/ring-\(moment.name)-\(Int(scale))x.png")
            }
        }
        writeGIF(exitRun(scale: 2, times: stride(from: 0.0, to: 3.6, by: 0.04).map { $0 }), to: "\(dir)/ring-exit-2x.gif")
        exit(0)
    }

    private enum State {
        case filling, overrun, spinning, flash
    }

    private static func session(_ id: String, role: String, title: String, parent: String = "", state: String = "working", cast: TrackerCast?) -> TrackerSession {
        TrackerSession(
            id: id, title: title, repoName: "questmaster", displayColor: "indigo", agent: "codex", role: role,
            state: state, parentID: parent, elapsedSeedMS: 80_000,
            narration: "It seems that something is still failing in the login flow.", cast: cast
        )
    }

    /// A master with its four workers collapsed and a master with its worker expanded, every one in `cast`'s state:
    /// the master disc, the worker disc and the collapsed circle side by side.
    private static func sessions(cast: (String) -> TrackerCast?) -> [TrackerSession] {
        let collapsed = (0..<4).map { session("qm-1-w\($0)", role: "worker", title: "worker-title", parent: "qm-1", cast: cast("qm-1-w\($0)")) }
        return [session("qm-1", role: "master", title: "Review PRs", cast: cast("qm-1"))] + collapsed + [
            session("qm-2", role: "master", title: "Plan release", cast: cast("qm-2")),
            session("qm-2-w", role: "worker", title: "worker-title", parent: "qm-2", cast: cast("qm-2-w")),
        ]
    }

    private static func store(_ sessions: [TrackerSession]) -> RuntimeStore {
        let store = RuntimeStore(sourceLabel: "preview", currentTerminalSessionID: "none", expandedMasterIDs: ["qm-2"])
        apply(sessions, to: store)
        return store
    }

    private static func apply(_ sessions: [TrackerSession], to store: RuntimeStore) {
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "questmaster", name: "questmaster", color: "indigo", sessions: sessions)])))
    }

    private static func view(_ store: RuntimeStore) -> some View {
        TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
        )
        .background(AppPalette.window.swiftUI)
        .frame(width: canvas.width, height: canvas.height)
    }

    private static func host(_ store: RuntimeStore, scale: CGFloat) -> (NSWindow, NSView) {
        let hosting = NSHostingView(rootView: view(store))
        hosting.frame = NSRect(origin: .zero, size: canvas)
        let window = HeadlessWindow(size: canvas, scale: scale)
        window.contentView = hosting
        window.show()
        wait(settle)
        return (window, hosting)
    }

    private static func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func still(_ state: State, scale: CGFloat, to path: String) {
        let now = Date()
        switch state {
        case .filling:
            let (window, hosting) = host(store(sessions { _ in TrackerCast(tool: "Bash", startedAt: now, typicalMS: 6000) }), scale: scale)
            wait(1.2)
            write(capture(hosting, scale: scale), to: path)
            window.orderOut(nil)
        case .overrun:
            let (window, hosting) = host(store(sessions { _ in TrackerCast(tool: "Bash", startedAt: now.addingTimeInterval(-9), typicalMS: 6000) }), scale: scale)
            // The pulse starts when the view configures; its first peak is half a period in.
            wait(TrackerCastFill.pulsePeriod / 2 - settle.truncatingRemainder(dividingBy: TrackerCastFill.pulsePeriod) + TrackerCastFill.pulsePeriod)
            write(capture(hosting, scale: scale), to: path)
            window.orderOut(nil)
        case .spinning:
            let (window, hosting) = host(store(sessions { _ in nil }), scale: scale)
            write(capture(hosting, scale: scale), to: path)
            window.orderOut(nil)
        case .flash:
            let cast = TrackerCast(tool: "Bash", startedAt: now.addingTimeInterval(-9), typicalMS: 6000)
            let runtime = store(sessions { _ in cast })
            let (window, hosting) = host(runtime, scale: scale)
            apply(sessions { _ in nil }, to: runtime)
            wait(0.05)
            write(capture(hosting, scale: scale), to: path)
            window.orderOut(nil)
        }
    }

    /// A master with collapsed workers through a few casts: the master fills Bash over 3s and runs past it, finishes,
    /// spins, then fills a quick Read; one worker fills Edit and finishes, one spins with no tool, one runs an MCP tool
    /// with no learned duration, one is blocked.
    private static func gif(to path: String) {
        let start = Date().addingTimeInterval(settle)
        func at(_ time: TimeInterval) -> [TrackerSession] {
            func cast(_ id: String) -> TrackerCast? {
                switch id {
                case "qm-1" where time < 4.5: TrackerCast(tool: "Bash", startedAt: start, typicalMS: 3000)
                case "qm-1" where time >= 5.5 && time < 6.5: TrackerCast(tool: "Read", startedAt: start.addingTimeInterval(5.5), typicalMS: 800)
                case "qm-1-w0" where time < 2.5: TrackerCast(tool: "Edit", startedAt: start, typicalMS: 2000)
                case "qm-1-w2": TrackerCast(tool: "mcp__linear__save_issue", startedAt: start, typicalMS: 0)
                default: nil
                }
            }
            let master = session("qm-1", role: "master", title: "Review PRs", cast: cast("qm-1"))
            let workers = (0..<4).map { index in
                session("qm-1-w\(index)", role: "worker", title: "worker-title", parent: "qm-1", state: index == 3 ? "blocked" : "working", cast: cast("qm-1-w\(index)"))
            }
            return [master] + workers
        }
        let runtime = store(at(0))
        let (window, hosting) = host(runtime, scale: 2)
        let framesPerSecond = 25.0
        var frames: [CGImage] = []
        let changes: [TimeInterval] = [2.5, 4.5, 5.5, 6.5]
        var applied = Set<TimeInterval>()
        let clock = Date()
        while Date().timeIntervalSince(clock) < 8 {
            let time = Date().timeIntervalSince(clock)
            for change in changes where time >= change && !applied.contains(change) {
                applied.insert(change)
                apply(at(change), to: runtime)
            }
            if let image = capture(hosting, scale: 2, rect: CGRect(x: 0, y: 100, width: canvas.width, height: 150)) {
                frames.append(image)
            }
            wait(1 / framesPerSecond)
        }
        window.orderOut(nil)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / framesPerSecond]] as CFDictionary
        frames.forEach { CGImageDestinationAddImage(destination, $0, delay) }
        CGImageDestinationFinalize(destination)
        print("RingPreview: wrote \(path) (\(frames.count) frames)")
    }

    /// A master and its collapsed workers stop working 1.5s in: the master is done (its ring completes in the done
    /// colour), one worker filling a cast goes idle (amber), one spinning stops, one working turns blocked (a crossfade
    /// to its steady ring), one on a tool with no learned duration is done. Captured at `times`, in the master and
    /// circles' band.
    private static func exitRun(scale: CGFloat, times: [TimeInterval]) -> [CGImage] {
        let start = Date().addingTimeInterval(settle)
        func at(_ time: TimeInterval) -> [TrackerSession] {
            let stopped = time >= 1.5
            func worker(_ index: Int, before: String, after: String, cast: TrackerCast?) -> TrackerSession {
                session("qm-1-w\(index)", role: "worker", title: "worker-title", parent: "qm-1", state: stopped ? after : before, cast: stopped ? nil : cast)
            }
            let master = session("qm-1", role: "master", title: "Review PRs", state: stopped ? "done" : "working",
                                 cast: stopped ? nil : TrackerCast(tool: "Bash", startedAt: start, typicalMS: 6000))
            return [master,
                    worker(0, before: "working", after: "idle", cast: TrackerCast(tool: "Edit", startedAt: start, typicalMS: 3000)),
                    worker(1, before: "working", after: "stopped", cast: nil),
                    worker(2, before: "working", after: "blocked", cast: nil),
                    worker(3, before: "working", after: "done", cast: TrackerCast(tool: "mcp__linear__save_issue", startedAt: start, typicalMS: 0))]
        }
        let runtime = store(at(0))
        let (window, hosting) = host(runtime, scale: scale)
        let clock = Date()
        var frames: [CGImage] = []
        var stopped = false
        for time in times.sorted() {
            while Date().timeIntervalSince(clock) < time {
                if !stopped && Date().timeIntervalSince(clock) >= 1.5 {
                    stopped = true
                    apply(at(1.5), to: runtime)
                }
                wait(0.005)
            }
            if let image = capture(hosting, scale: scale, rect: CGRect(x: 0, y: 100, width: canvas.width, height: 120)) {
                frames.append(image)
            }
        }
        window.orderOut(nil)
        return frames
    }

    static func writeGIF(_ frames: [CGImage], to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.04]] as CFDictionary
        frames.forEach { CGImageDestinationAddImage(destination, $0, delay) }
        CGImageDestinationFinalize(destination)
        print("RingPreview: wrote \(path) (\(frames.count) frames)")
    }

    /// The hosting view as Core Animation is showing it right now: its presentation layers rendered into a bitmap.
    private static func capture(_ hosting: NSView, scale: CGFloat, rect: CGRect? = nil) -> CGImage? {
        let rect = rect ?? hosting.bounds
        let size = rect.size
        guard let layer = hosting.layer,
              let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // The hosting layer's content runs top down; the bitmap's y runs up.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        (layer.presentation() ?? layer).render(in: context)
        return context.makeImage()
    }

    static func write(_ image: CGImage?, to path: String) {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("RingPreview: wrote \(path)")
    }
}
#endif
