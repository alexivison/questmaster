import SwiftUI

@MainActor
public struct GhosttyTerminal: View {
    @State private var session: GhosttyTerminalSession
    private let configuration: GhosttyTerminalViewConfiguration

    public init(
        launchConfiguration: GhosttyTerminalLaunchConfiguration = GhosttyTerminalLaunchConfiguration(),
        configuration: GhosttyTerminalViewConfiguration = GhosttyTerminalViewConfiguration()
    ) {
        self._session = State(initialValue: GhosttyTerminalSession(configuration: launchConfiguration))
        self.configuration = configuration
    }

    public var body: some View {
        GhosttyTerminalRepresentable(session: session, configuration: configuration)
    }
}

@MainActor
public struct GhosttyTerminalRepresentable: NSViewRepresentable {
    public let session: GhosttyTerminalSession
    public var configuration: GhosttyTerminalViewConfiguration

    public init(
        session: GhosttyTerminalSession? = nil,
        configuration: GhosttyTerminalViewConfiguration = GhosttyTerminalViewConfiguration()
    ) {
        self.session = session ?? GhosttyTerminalSession()
        self.configuration = configuration
    }

    public func makeNSView(context: Context) -> GhosttyTerminalView {
        session.makeView(configuration: configuration)
    }

    public func updateNSView(_ nsView: GhosttyTerminalView, context: Context) {
        nsView.apply(configuration: configuration)
    }
}
