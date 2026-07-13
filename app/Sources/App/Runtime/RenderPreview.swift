import AppKit
import QuestmasterCore
import SwiftUI

/// Dev-only: renders real production views off-screen to PNGs so layout fixes
/// can be pixel-checked without a running GUI session. Not for shipping —
/// gated behind DEBUG, same as LogicSelfTests.
#if DEBUG
enum RenderPreview {
    @MainActor
    static func runIfRequested() -> Bool {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--render-preview") else {
            return false
        }
        let outputDir = CommandLine.arguments.count > flagIndex + 1
            ? CommandLine.arguments[flagIndex + 1]
            : NSTemporaryDirectory()

        render(newSessionView(), size: CGSize(width: 540, height: 580), to: "\(outputDir)/new-session.png")
        render(confirmationView(), size: CGSize(width: 420, height: 300), autoHeight: true, to: "\(outputDir)/confirmation.png")
        render(sectionHeaderView(), size: CGSize(width: 220, height: 40), to: "\(outputDir)/section-header.png")
        print("RenderPreview: done")
        exit(0)
    }

    @MainActor
    private static func newSessionView() -> some View {
        let state = NewSessionViewState(model: NewSessionFormModel(
            role: .standalone,
            initialPath: "/",
            initialFocus: .path
        ))
        state.pathSuggestions = [
            "/Users/aleksi.tuominen/Code",
            "/Users/aleksi.tuominen/Code/questmaster",
            "/Users/aleksi.tuominen/Code/dotfiles",
        ]
        return NewSessionRootView(
            state: state,
            onFocusChanged: { _ in },
            onPathChanged: {},
            onCreate: {},
            onCancel: {}
        )
        .background(AppPalette.panel.swiftUI)
    }

    private static func confirmationView() -> some View {
        DestructiveConfirmationSheetView(
            spec: .deleteSession(sessionID: "qm-1783901769"),
            onDecision: { _ in }
        )
    }

    private static func sectionHeaderView() -> some View {
        SectionHeader(title: "questmaster", color: NSColor(hex: 0xd29922))
            .background(AppPalette.panel.swiftUI)
    }

    @MainActor
    private static func render<V: View>(_ view: V, size: CGSize, autoHeight: Bool = false, to path: String) {
        // ImageRenderer can't host NSViewRepresentable-backed controls (text
        // fields, prompt editor) correctly off-screen — they render as an
        // opaque placeholder. A real (off-screen-positioned) window + the
        // classic AppKit view-snapshot API handles them properly since the
        // views get an actual window/layer to draw into.
        let rootView = autoHeight ? AnyView(view.frame(width: size.width)) : AnyView(view.frame(width: size.width, height: size.height))
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10000, y: -10000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        if autoHeight {
            let fitting = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: CGSize(width: size.width, height: fitting.height))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            print("RenderPreview: failed to create bitmap for \(path)")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        window.orderOut(nil)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            print("RenderPreview: failed to encode \(path)")
            return
        }
        do {
            try pngData.write(to: URL(fileURLWithPath: path))
            print("RenderPreview: wrote \(path)")
        } catch {
            print("RenderPreview: write failed for \(path): \(error)")
        }
    }
}
#endif
