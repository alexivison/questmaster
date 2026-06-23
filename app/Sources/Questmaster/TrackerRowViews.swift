import AppKit
import QuestmasterCore

final class TrackerSessionRowView: NSView {
    private let agent = TrackerAgentMarkView()
    private let title = NSTextField(labelWithString: "")
    private let status: TrackerStatusBadgeView
    private let snippet = NSTextField(labelWithString: "")
    private let pathIcon = NSImageView()
    private let pathRow = NSStackView()
    private let meta = NSTextField(labelWithString: "")
    private var session: TrackerSession?

    init(rendered: TrackerRenderedSession, selected: Bool, tick: Int, now: Date) {
        status = TrackerStatusBadgeView(
            status: rendered.status,
            duration: TrackerRenderer.durationLabel(for: rendered.session, now: now),
            tick: tick
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let agentTitleGap = rendered.depth == 0
            ? RepoSectionedListMetrics.topLevelAgentGap
            : RepoSectionedListMetrics.workerTreeToAgentGap

        agent.translatesAutoresizingMaskIntoConstraints = false

        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false

        status.translatesAutoresizingMaskIntoConstraints = false
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = NSView()
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addSubview(title)
        titleRow.addSubview(status)

        let main = NSStackView()
        main.orientation = .vertical
        main.alignment = .leading
        main.spacing = 2
        main.detachesHiddenViews = true
        main.translatesAutoresizingMaskIntoConstraints = false
        main.addArrangedSubview(titleRow)

        snippet.font = NSFontManager.shared.convert(AppFonts.monoSmall, toHaveTrait: .italicFontMask)
        snippet.textColor = AppPalette.muted
        snippet.lineBreakMode = .byTruncatingTail
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        main.addArrangedSubview(snippet)

        pathIcon.imageScaling = .scaleProportionallyDown
        pathIcon.setContentCompressionResistancePriority(.required, for: .horizontal)
        pathIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pathIcon.widthAnchor.constraint(equalToConstant: 12),
            pathIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
        meta.font = AppFonts.monoSmall
        meta.textColor = AppPalette.dim
        meta.lineBreakMode = .byTruncatingMiddle
        meta.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 5
        pathRow.translatesAutoresizingMaskIntoConstraints = false
        pathRow.addArrangedSubview(pathIcon)
        pathRow.addArrangedSubview(meta)
        main.addArrangedSubview(pathRow)

        addSubview(agent)
        addSubview(main)

        NSLayoutConstraint.activate([
            agent.leadingAnchor.constraint(equalTo: leadingAnchor),
            agent.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            agent.widthAnchor.constraint(equalToConstant: TrackerAgentGlyphMetrics.columnWidth),
            agent.heightAnchor.constraint(equalToConstant: RepoSectionedListMetrics.trackerAgentFrameHeight),

            main.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            main.leadingAnchor.constraint(equalTo: agent.trailingAnchor, constant: agentTitleGap),
            main.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -RepoSectionedListMetrics.rowTrailingInset),
            main.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            titleRow.widthAnchor.constraint(equalTo: main.widthAnchor),
            titleRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
            title.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
            title.topAnchor.constraint(equalTo: titleRow.topAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -8),
            status.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),
            status.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        update(rendered: rendered, selected: selected, tick: tick, now: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var statusIndicator: StatusIndicatorView {
        status.statusIndicator
    }

    func update(rendered: TrackerRenderedSession, selected: Bool, tick: Int, now: Date) {
        session = rendered.session
        agent.update(agent: rendered.session.agent)

        title.stringValue = rendered.session.title.isEmpty ? rendered.session.id : rendered.session.title
        title.font = rendered.session.isCurrent || selected ? AppFonts.bodyBold : AppFonts.body
        title.textColor = selected ? AppPalette.bright : AppPalette.text

        status.update(
            status: rendered.status,
            duration: TrackerRenderer.durationLabel(for: rendered.session, now: now),
            tick: tick
        )

        let snippetValue = TrackerRenderer.snippet(for: rendered.session)
        snippet.stringValue = snippetValue
        snippet.isHidden = snippetValue.isEmpty

        let path = TrackerRenderer.metadata(for: rendered.session)
        meta.stringValue = path
        pathRow.isHidden = path.isEmpty
        pathIcon.image = AppSymbolStyle.image(name: "folder", color: AppPalette.dim)
    }

    func updateDurationLabel(now: Date) {
        guard let session else {
            return
        }
        status.updateDuration(TrackerRenderer.durationLabel(for: session, now: now))
    }
}

private final class TrackerAgentMarkView: NSView {
    private var agentName = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(agent: String) {
        let clean = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean != agentName else {
            return
        }
        agentName = clean
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = AppPalette.agent(agentName)
        let rect = bounds
        color.setFill()
        let diameter = min(TrackerAgentGlyphMetrics.dotDiameter, rect.width, rect.height)
        let dotRect = NSRect(
            x: rect.midX - diameter / 2,
            y: rect.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        NSBezierPath(ovalIn: dotRect).fill()
    }
}

private final class TrackerStatusBadgeView: NSStackView {
    private let dot: StatusIndicatorView
    private let label = NSTextField(labelWithString: "")
    private var durationLabel: NSTextField?

    init(status: TrackerStatusStyle, duration: String, tick: Int) {
        dot = StatusIndicatorView(status: status, tick: tick)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
        ])

        label.font = AppFonts.monoSmall

        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 5
        addArrangedSubview(dot)
        addArrangedSubview(label)
        update(status: status, duration: duration, tick: tick)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var statusIndicator: StatusIndicatorView {
        dot
    }

    func update(status: TrackerStatusStyle, duration: String, tick: Int) {
        label.stringValue = status.label
        label.textColor = status.color
        dot.setTick(tick)
        updateDuration(duration)
    }

    func updateDuration(_ duration: String) {
        if duration.isEmpty {
            if let durationLabel {
                removeArrangedSubview(durationLabel)
                durationLabel.removeFromSuperview()
                self.durationLabel = nil
            }
            return
        }
        let durationLabel: NSTextField
        if let existing = self.durationLabel {
            durationLabel = existing
        } else {
            durationLabel = NSTextField(labelWithString: "")
            durationLabel.font = AppFonts.monoSmall
            durationLabel.textColor = AppPalette.dim
            addArrangedSubview(durationLabel)
            self.durationLabel = durationLabel
        }
        durationLabel.stringValue = duration
    }
}

final class StatusIndicatorView: NSView {
    private let status: TrackerStatusStyle
    private var tick: Int
    private let selected: Bool

    init(status: TrackerStatusStyle, tick: Int, selected: Bool = false) {
        self.status = status
        self.tick = tick
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTick(_ tick: Int) {
        guard status.indicatorAffordance == .spinner, self.tick != tick else {
            return
        }
        self.tick = tick
        needsDisplay = true
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        if selected {
            AppPalette.bright.withAlphaComponent(0.8).setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }

        if status.indicatorAffordance == .spinner {
            status.color.setStroke()
            let path = NSBezierPath()
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let radius = min(rect.width, rect.height) / 2
            let rotation = CGFloat((tick % 8) * 45)
            path.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: -80 + rotation,
                endAngle: 220 + rotation,
                clockwise: false
            )
            path.lineWidth = 2
            path.stroke()
            return
        }

        status.color.setFill()
        switch status.indicatorAffordance {
        case .square:
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        case .roundedSquare:
            status.color.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        default:
            NSBezierPath(ovalIn: rect).fill()
        }

        if status.indicatorAffordance == .ring {
            status.color.withAlphaComponent(0.55).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -2, dy: -2))
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}
