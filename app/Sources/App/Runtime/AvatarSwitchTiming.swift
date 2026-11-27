#if DEBUG
import AppKit
import QuestmasterCore
import SwiftUI

/// Dev-only avatar measurements. Run in a fresh process so the art starts cold.
///
/// - Cache sweep: `RENDER_ONLY=avatar-cache-sweep`, a synthetic pose sweep and a warm off-screen switch.
/// - Switch timing: `RENDER_ONLY=avatar-switch-timing`.
/// - Cold build: each class's, familiar's and company's art built from fresh sprites, with what the first show of each pose costs.
/// - Prefetch: the tracker's prefetch settles first (`AVATAR_SWITCH_NOWAIT=1` skips the wait, to time a switch right after a payload).
/// - Switch: the tracker, hosted headless as the app hosts it, is switched with `setCurrentTerminalSessionID`, the call an attach makes.
///   `notify` runs the observer that feeds the avatar; `shown` runs until a slot view has the attached art and pose.
/// - Repeat: the same payload observed again, what each tracker update and company wake costs on the main thread.
@MainActor
enum AvatarSwitchTiming {
    static func runIfRequested(to dir: String) {
        let modes = ProcessInfo.processInfo.environment["RENDER_ONLY"]?.split(separator: ",") ?? []
        guard modes.contains("avatar-switch-timing") || modes.contains("avatar-cache-sweep") else {
            return
        }
        var lines: [String] = []
        func log(_ line: String) {
            print(line)
            lines.append(line)
        }
        if modes.contains("avatar-cache-sweep") {
            cacheSweepReport(log)
            try? (lines.joined(separator: "\n") + "\n").write(toFile: "\(dir)/avatar-cache-sweep.txt", atomically: true, encoding: .utf8)
            return
        }

        let libraryStart = now()
        _ = TrackerAvatarLibrary.sprites
        _ = TrackerAvatarLibrary.companions
        _ = TrackerAvatarLibrary.catalog
        log(String(format: "library first load (static, all classes): %.2f ms", ms(since: libraryStart)))
        coldBuildReport(log)
        let noWait = ProcessInfo.processInfo.environment["AVATAR_SWITCH_NOWAIT"] == "1"
        trackerSwitchReport(noWait: noWait, log)
        stageRepeatReport(log)
        try? (lines.joined(separator: "\n") + "\n").write(toFile: "\(dir)/avatar-switch-timing.txt", atomically: true, encoding: .utf8)
    }

    /// A repeatable 33-session synthetic pose sweep across every class, followed by a warm off-screen switch.
    private static func cacheSweepReport(_ log: (String) -> Void) {
        _ = TrackerAvatarLibrary.sprites
        _ = TrackerAvatarLibrary.companions
        _ = TrackerAvatarLibrary.catalog
        let beforeBytes = TrackerAvatarLibrary.cachedByteCount
        var sessions = cacheSweepSessions()
        let sessionCount = sessions.count
        log("synthetic avatar cache sweep: 33 sessions (11 masters, 22 workers), all 11 classes; master=studying, workers=pondering+working")
        let prefetchStart = now()
        TrackerAvatarLibrary.prefetch(for: sessions)
        sessions.removeAll(keepingCapacity: false)
        let prefetchWait = waitForCacheStability(timeout: 240)
        guard prefetchWait.settled else {
            log("sweep did not settle before timeout")
            exit(1)
        }
        let afterBytes = TrackerAvatarLibrary.cachedByteCount
        let afterFrames = TrackerAvatarLibrary.cachedFrameCount
        log(String(
            format: "sweep settled=%@ wait %.0f ms; decoded cache %.1f MiB before, %.1f MiB after (%+.1f MiB), %d frames",
            prefetchWait.settled ? "yes" : "no",
            ms(since: prefetchStart),
            Double(beforeBytes) / 1_048_576,
            Double(afterBytes) / 1_048_576,
            Double(afterBytes - beforeBytes) / 1_048_576,
            afterFrames
        ))
        log("released synthetic session rows: \(sessionCount)")

        let warmSession = cacheSession(
            "qm-cache-warm-switch", sessionClass: SessionClass.allCases[0].rawValue, state: "working", tool: "Read"
        )
        guard let warmKey = TrackerAvatarLibrary.catalog.art(for: warmSession),
              let warmSprites = TrackerAvatarLibrary.sprites[warmKey],
              let warmPose = TrackerAvatarPose.pose(for: warmSession, catalog: TrackerAvatarLibrary.catalog) else {
            log("warm switch unavailable: synthetic master art did not load")
            return
        }
        TrackerAvatarLibrary.prefetch(for: [warmSession])
        guard waitForCacheStability(timeout: 30).settled else {
            log("warm switch prefetch did not settle before timeout")
            exit(1)
        }
        let view = TrackerAvatarView(frame: NSRect(
            x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight
        ))
        view.sprites = warmSprites
        let decodeCount = TrackerAvatarDecodeProbe.count
        let switchStart = now()
        view.configure(pose: warmPose, beat: 0, finish: nil, reduceMotion: false)
        let synchronousDecodes = TrackerAvatarDecodeProbe.count - decodeCount
        log(String(
            format: "warm off-screen switch: %@ %@ in %.2f ms; synchronous frame decodes %d",
            warmSession.id, String(describing: warmPose), ms(since: switchStart), synchronousDecodes
        ))
        if view.probePose != warmPose || synchronousDecodes != 0 {
            log("warm switch check failed")
            exit(1)
        }
    }

    private static func waitForCacheStability(timeout: TimeInterval) -> (settled: Bool, elapsed: TimeInterval) {
        let started = now()
        while now() - started < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if TrackerAvatarSprites.outstandingPrefetchWork == 0 {
                return (true, now() - started)
            }
        }
        return (false, now() - started)
    }

    private static func cacheSweepSessions() -> [TrackerSession] {
        var rows: [TrackerSession] = []
        for sessionClass in SessionClass.allCases {
            let masterID = "qm-cache-\(sessionClass.rawValue)"
            rows.append(cacheSession(masterID, sessionClass: sessionClass.rawValue, state: "working", tool: "Read"))
            rows.append(cacheSession(
                "\(masterID)-pondering", sessionClass: sessionClass.rawValue, parent: masterID, state: "working"
            ))
            rows.append(cacheSession(
                "\(masterID)-working", sessionClass: sessionClass.rawValue, parent: masterID, state: "working", tool: "Edit"
            ))
        }
        return rows
    }

    private static func cacheSession(
        _ id: String,
        sessionClass: String,
        parent: String = "",
        state: String,
        tool: String? = nil
    ) -> TrackerSession {
        var fields: [String: Any] = [
            "id": id, "title": id, "status": "active", "state": state, "agent": "claude",
            "parent_id": parent, "worker_count": 0, "elapsed_ms": 0, "class": sessionClass, "active_subagents": 0,
        ]
        if let tool {
            fields["cast"] = ["tool": tool, "started_at": "2026-11-27T00:00:00Z", "typical_ms": 0]
        }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(TrackerSession.self, from: data)
    }

    /// Each class's art, the familiars' and the companies', built from fresh sprites: what the first show of each pose costs in decodes.
    private static func coldBuildReport(_ log: (String) -> Void) {
        guard let resources = AppSymbolStyle.resourceBundle().resourceURL else {
            return
        }
        let shared = resources.appendingPathComponent("Sprites/shared", isDirectory: true)
        log("cold build, fresh sprites per folder (ms): decodeAll = every PNG read and drawn; init = sprites and idle figure;")
        log("  fidgets = availableFidgets; poses = configure each pose once on a new view; frames = PNGs decoded on that path")
        for sessionClass in SessionClass.allCases {
            let classID = sessionClass.rawValue
            let folders: [(String, TrackerAvatarArtKind, URL)] = [
                ("master", .master, resources.appendingPathComponent("Sprites/\(classID)", isDirectory: true)),
                ("familiar", .familiar, resources.appendingPathComponent("Familiars/\(classID)", isDirectory: true)),
                ("company", .familiar, resources.appendingPathComponent("Familiars/\(classID)/company", isDirectory: true)),
            ]
            for (name, kind, folder) in folders where FileManager.default.fileExists(atPath: folder.path) {
                let decodeAll = decodeEveryPNG(in: folder)
                let decodesBefore = TrackerAvatarDecodeProbe.count
                let secondsBefore = TrackerAvatarDecodeProbe.seconds
                let initStart = now()
                guard let sprites = TrackerAvatarSprites(classID: classID, folder: folder, kind: kind, bubbleFolder: shared) else {
                    log("\(classID) \(name): no animation.json")
                    continue
                }
                let initMs = ms(since: initStart)
                let fidgetStart = now()
                _ = sprites.availableFidgets
                let fidgetMs = ms(since: fidgetStart)
                let view = TrackerAvatarView(frame: NSRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight))
                view.sprites = sprites
                var poseTotal = 0.0
                var poseMax = (ms: 0.0, pose: "")
                for pose in TrackerAvatarPose.allCases where sprites.animation.animation(for: pose) != nil {
                    let poseStart = now()
                    view.configure(pose: pose, beat: 0, finish: nil, reduceMotion: false)
                    let elapsed = ms(since: poseStart)
                    poseTotal += elapsed
                    if elapsed > poseMax.ms {
                        poseMax = (elapsed, String(describing: pose))
                    }
                }
                let frames = TrackerAvatarDecodeProbe.count - decodesBefore
                let frameMs = (TrackerAvatarDecodeProbe.seconds - secondsBefore) * 1000
                log(String(
                    format: "%-10@ %-8@ decodeAll %7.2f  init %6.2f  fidgets %6.2f  poses %7.2f (max %6.2f %@)  frames %3d  decode %7.2f",
                    classID, name, decodeAll, initMs, fidgetMs, poseTotal, poseMax.ms, poseMax.pose, frames, frameMs
                ))
            }
        }
    }

    /// Decodes and draws every PNG in `folder`, the full cost of the art with nothing cached. Returns the milliseconds.
    private static func decodeEveryPNG(in folder: URL) -> Double {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let start = now()
        for file in files where file.pathExtension == "png" {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let context = CGContext(
                      data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                continue
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return ms(since: start)
    }

    /// The tracker, hosted headless the way the app hosts it, switched the way the attach does: `setCurrentTerminalSessionID` runs the
    /// tracker's observer (`feedAvatar`), and the timing ends when a slot view shows the attached session's art and pose.
    private static func trackerSwitchReport(noWait: Bool, _ log: (String) -> Void) {
        let sessions = sampleSessions()
        let store = RuntimeStore(sourceLabel: "avatar-switch", currentTerminalSessionID: nil, expandedMasterIDs: ["qm-a", "qm-b", "qm-c"])
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "questmaster", name: "Questmaster", color: "yellow", sessions: sessions)])))
        let root = TrackerRootView(store: store, newSessionPresenter: NewSessionSheetPresenter(), destructiveConfirmationPresenter: DestructiveConfirmationPresenter())
        let host = NSHostingView(rootView: root)
        let size = CGSize(width: 320, height: 800)
        host.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size)
        window.contentView = host
        window.show()
        RunLoop.current.run(until: Date().addingTimeInterval(noWait ? 0.02 : 0.3))
        if !noWait {
            awaitPrefetch(log)
        }
        let attachedSequence = ["qm-a", "qm-a1", "qm-b", "qm-b1", "qm-a", "qm-c", "qm-a2", "qm-b", "qm-a"]
        log("tracker switch: notify = setCurrentTerminalSessionID (the observer, feedAvatar, both stages); shown = until a slot view has the attached art and pose")
        for (index, attached) in attachedSequence.enumerated() {
            guard let session = sessions.first(where: { $0.id == attached }) else {
                continue
            }
            let catalog = TrackerAvatarLibrary.catalog
            let expectedSprites = catalog.art(for: session).flatMap { TrackerAvatarLibrary.sprites[$0] }
            let expectedPose = TrackerAvatarPose.pose(for: session, catalog: catalog)
            let decodesBefore = TrackerAvatarDecodeProbe.count
            let secondsBefore = TrackerAvatarDecodeProbe.seconds
            let start = now()
            store.setCurrentTerminalSessionID(attached)
            let notifyMs = ms(since: start)
            let shown = settle(host, sprites: expectedSprites, pose: expectedPose, timeout: 3)
            let frames = TrackerAvatarDecodeProbe.count - decodesBefore
            let frameMs = (TrackerAvatarDecodeProbe.seconds - secondsBefore) * 1000
            log(String(
                format: "%2d %-6@ notify %7.2f ms  shown %@  decoded %3d (%6.2f ms)  pose %@",
                index + 1, attached, notifyMs, shown.map { String(format: "%7.2f ms", $0 * 1000) } ?? "timeout",
                frames, frameMs, expectedPose.map { String(describing: $0) } ?? "none"
            ))
        }
        window.close()
    }

    /// Runs the run loop until the tracker's prefetch has stopped adding frames for 0.6 s, and reports what it decoded.
    private static func awaitPrefetch(_ log: (String) -> Void) {
        let waitStart = now()
        var stableSince = now()
        var last = TrackerAvatarLibrary.cachedFrameCount
        while now() - waitStart < 20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            let count = TrackerAvatarLibrary.cachedFrameCount
            if count != last {
                last = count
                stableSince = now()
            } else if now() - stableSince > 0.6 {
                break
            }
        }
        log(String(
            format: "prefetch settled: %d frames, %.1f MB decoded, after %.0f ms",
            last, Double(TrackerAvatarLibrary.cachedByteCount) / 1_048_576, ms(since: waitStart)
        ))
    }

    /// One master's company observed again with nothing changed: the main-thread cost each tracker update and company wake pays.
    private static func stageRepeatReport(_ log: (String) -> Void) {
        let sessions = sampleSessions()
        let avatar = TrackerAvatarStage()
        let company = TrackerCompanyStage()
        avatar.observe(sessions: sessions, attachedID: "qm-a")
        company.observe(sessions: sessions, attachedID: "qm-a")
        var repeats: [String] = []
        for _ in 0..<5 {
            let start = now()
            avatar.observe(sessions: sessions, attachedID: "qm-a")
            let avatarMs = ms(since: start)
            let companyStart = now()
            company.observe(sessions: sessions, attachedID: "qm-a")
            repeats.append(String(format: "%.2f+%.2f", avatarMs, ms(since: companyStart)))
        }
        log("same payload, attached qm-a, observed again (ms, avatar+company): " + repeats.joined(separator: "  "))
    }

    /// Runs the run loop until a slot view shows `sprites` at `pose`, returning the seconds that took; nil on timeout.
    private static func settle(_ host: NSView, sprites: TrackerAvatarSprites?, pose: TrackerAvatarPose?, timeout: TimeInterval) -> TimeInterval? {
        guard let sprites, let pose else {
            return 0
        }
        let start = now()
        while true {
            if avatarViews(in: host).contains(where: { $0.sprites === sprites && $0.probePose == pose }) {
                return now() - start
            }
            if now() - start > timeout {
                return nil
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.0005))
        }
    }

    private static func avatarViews(in view: NSView) -> [TrackerAvatarView] {
        var found: [TrackerAvatarView] = []
        if let avatarView = view as? TrackerAvatarView {
            found.append(avatarView)
        }
        for subview in view.subviews {
            found += avatarViews(in: subview)
        }
        return found
    }

    /// The master's class, its workers, and two more masters with theirs: the sessions the switches move between.
    private static func sampleSessions() -> [TrackerSession] {
        var rows = [session("qm-a", sessionClass: "bard", state: "idle"), session("qm-b", sessionClass: "cleric", state: "idle"), session("qm-c", sessionClass: "wizard", state: "idle")]
        for index in 1...4 {
            rows.append(session("qm-a\(index)", sessionClass: "bard", parent: "qm-a", state: "working"))
        }
        for index in 1...3 {
            rows.append(session("qm-b\(index)", sessionClass: "cleric", parent: "qm-b", state: "working"))
        }
        for index in 1...2 {
            rows.append(session("qm-c\(index)", sessionClass: "wizard", parent: "qm-c", state: "working"))
        }
        return rows
    }

    private static func session(_ id: String, sessionClass: String, parent: String = "", state: String) -> TrackerSession {
        let fields: [String: Any] = [
            "id": id, "title": id, "status": "active", "state": state, "agent": "claude",
            "parent_id": parent, "worker_count": 0, "elapsed_ms": 0, "class": sessionClass, "active_subagents": 0,
        ]
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return try! JSONDecoder().decode(TrackerSession.self, from: data)
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func ms(since start: TimeInterval) -> Double {
        (now() - start) * 1000
    }
}
#endif
