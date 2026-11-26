import AppKit
import SwiftUI

struct ScrollOverflow: Equatable {
    var before = false
    var after = false
}

/// Reads the AppKit viewport so trackpad scrolling, scrollTo, and layout changes all update the fades.
struct ScrollOverflowObserver: NSViewRepresentable {
    let axis: Axis
    let onChange: (ScrollOverflow) -> Void

    func makeNSView(context: Context) -> ScrollOverflowObserverView {
        ScrollOverflowObserverView()
    }

    func updateNSView(_ view: ScrollOverflowObserverView, context: Context) {
        view.axis = axis
        view.onChange = onChange
    }
}

final class ScrollOverflowObserverView: NSView {
    var axis: Axis = .vertical
    var onChange: ((ScrollOverflow) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var reported: ScrollOverflow?
    private var reportPending = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        reported = nil
        guard window != nil, let scrollView = enclosingScrollView, let documentView = scrollView.documentView else {
            return
        }

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        documentView.postsFrameChangedNotifications = true
        let sources: [(Notification.Name, NSView)] = [
            (NSView.boundsDidChangeNotification, clipView),
            (NSView.frameDidChangeNotification, clipView),
            (NSView.frameDidChangeNotification, documentView),
        ]
        observers = sources.map { name, view in
            NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReport() }
            }
        }
        scheduleReport()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func scheduleReport() {
        guard !reportPending else { return }
        reportPending = true
        // Layout notifications can arrive inside a SwiftUI update. Report once after layout settles.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reportPending = false
            report()
        }
    }

    private func report() {
        guard window != nil, let scrollView = enclosingScrollView, let documentView = scrollView.documentView else {
            return
        }
        let visible = scrollView.documentVisibleRect
        let document = documentView.bounds
        // Ignore fractional layout differences at an edge.
        let tolerance: CGFloat = 0.5
        let overflow: ScrollOverflow
        switch axis {
        case .horizontal:
            overflow = ScrollOverflow(
                before: visible.minX - document.minX > tolerance,
                after: document.maxX - visible.maxX > tolerance
            )
        case .vertical:
            let aboveMinY = visible.minY - document.minY > tolerance
            let belowMaxY = document.maxY - visible.maxY > tolerance
            overflow = documentView.isFlipped
                ? ScrollOverflow(before: aboveMinY, after: belowMaxY)
                : ScrollOverflow(before: belowMaxY, after: aboveMinY)
        }
        guard reported != overflow else { return }
        reported = overflow
        onChange?(overflow)
    }
}
