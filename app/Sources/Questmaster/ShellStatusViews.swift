import AppKit
import QuestmasterCore

final class ServeStatusPillView: NSView {
    private let indicator = ServePillIndicatorView()
    private let label = NSTextField(labelWithString: "serve")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7

        label.font = AppFonts.monoSmall
        label.textColor = AppPalette.muted
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true

        let stackView = NSStackView(views: [indicator, label])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 11),
            indicator.heightAnchor.constraint(equalToConstant: 11),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setConnectionState(_ state: ServeConnectionState) {
        let labelText: String
        let indicatorMode: ServePillIndicatorMode
        let indicatorColor: NSColor

        switch state {
        case .ready:
            labelText = "serve"
            indicatorMode = .dot
            indicatorColor = AppPalette.added
            label.textColor = AppPalette.muted
            layer?.backgroundColor = AppPalette.panel.cgColor
            layer?.borderColor = AppPalette.line.cgColor
        case .starting:
            labelText = "starting serve…"
            indicatorMode = .spinner
            indicatorColor = AppPalette.trackerWorking
            label.textColor = AppPalette.trackerWorking
            layer?.backgroundColor = AppPalette.trackerWorking.withAlphaComponent(0.1).cgColor
            layer?.borderColor = AppPalette.trackerWorking.withAlphaComponent(0.3).cgColor
        case .error:
            labelText = "serve error"
            indicatorMode = .dot
            indicatorColor = AppPalette.trackerError
            label.textColor = AppPalette.trackerError
            layer?.backgroundColor = AppPalette.trackerError.withAlphaComponent(0.1).cgColor
            layer?.borderColor = AppPalette.trackerError.withAlphaComponent(0.3).cgColor
        }

        toolTip = labelText
        label.stringValue = labelText
        indicator.setMode(indicatorMode, color: indicatorColor)
    }
}

final class TerminalMessageOverlayView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.terminal.withAlphaComponent(0.96).cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = AppPalette.text
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = AppFonts.body
        detailLabel.textColor = AppPalette.muted
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping

        let stackView = NSStackView(views: [titleLabel, detailLabel])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, detail: String) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        toolTip = detail
    }
}

final class MutationErrorBannerView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.trackerError.withAlphaComponent(0.18).cgColor
        layer?.borderColor = AppPalette.trackerError.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 8

        label.font = AppFonts.body
        label.textColor = AppPalette.text
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            widthAnchor.constraint(lessThanOrEqualToConstant: 560),
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(message: String) {
        label.stringValue = message
        toolTip = message
    }
}

private enum ServePillIndicatorMode {
    case dot
    case spinner
}

private final class ServePillIndicatorView: NSView {
    private var mode: ServePillIndicatorMode = .dot
    private var color = AppPalette.added
    private var tick = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    func setMode(_ mode: ServePillIndicatorMode, color: NSColor) {
        self.mode = mode
        self.color = color
        updateTimer()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        guard window != nil, mode == .spinner else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else {
            return
        }
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.tick = ((self?.tick ?? 0) + 1) % 64
            self?.needsDisplay = true
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        switch mode {
        case .dot:
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5)).fill()
        case .spinner:
            color.setStroke()
            let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let path = NSBezierPath()
            let rotation = CGFloat((tick % 10) * 36)
            path.appendArc(
                withCenter: NSPoint(x: bounds.midX, y: bounds.midY),
                radius: min(rect.width, rect.height) / 2,
                startAngle: -80 + rotation,
                endAngle: 220 + rotation,
                clockwise: false
            )
            path.lineWidth = 2
            path.stroke()
        }
    }
}
