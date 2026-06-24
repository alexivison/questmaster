import AppKit

func isServeStartingMessage(_ message: String?) -> Bool {
    let lowercased = message?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return lowercased.contains("connecting") || lowercased.contains("starting")
}

enum SkeletonPlaceholderKind {
    case tracker
    case questList
    case questDetail
}

final class SkeletonPlaceholderView: NSView {
    private let kind: SkeletonPlaceholderKind
    private let stackView = NSStackView()

    init(kind: SkeletonPlaceholderKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var backgroundColor: NSColor {
        switch kind {
        case .tracker:
            return AppPalette.panel
        case .questList:
            return AppPalette.questListColumn
        case .questDetail:
            return AppPalette.questViewerBackground
        }
    }

    private func setup() {
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        let insets = insets
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -insets.right),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -insets.bottom),
        ])

        switch kind {
        case .tracker:
            addTrackerRows()
        case .questList:
            addQuestListRows()
        case .questDetail:
            addQuestDetailRows()
        }
    }

    private var insets: NSEdgeInsets {
        switch kind {
        case .tracker:
            return NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        case .questList:
            return NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        case .questDetail:
            return NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        }
    }

    private func addTrackerRows() {
        addBar(width: 88, height: 8, top: 4, bottom: 8)
        addDotRow(indent: 0, width: 150)
        addDotRow(indent: 18, width: 185)
        addDotRow(indent: 18, width: 120)
        addBar(width: 96, height: 8, top: 14, bottom: 8)
        addDotRow(indent: 0, width: 160)
    }

    private func addQuestListRows() {
        for (titleWidth, metaWidth) in [(118, 74), (145, 66), (104, 82)] {
            let group = NSStackView()
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 6
            group.translatesAutoresizingMaskIntoConstraints = false
            group.addArrangedSubview(SkeletonBarView(width: CGFloat(titleWidth), height: 9, color: AppPalette.controlFill))
            group.addArrangedSubview(SkeletonBarView(width: CGFloat(metaWidth), height: 7, color: AppPalette.lineSoftSubtle))
            stackView.addArrangedSubview(group)
            stackView.setCustomSpacing(14, after: group)
        }
    }

    private func addQuestDetailRows() {
        addBar(width: 180, height: 18, bottom: 14)
        addBar(width: 112, height: 9, color: AppPalette.lineSoftSubtle, bottom: 24)
        addBar(width: 310, height: 9, bottom: 7)
        addBar(width: 286, height: 9, bottom: 7)
        addBar(width: 230, height: 9, bottom: 26)
        addGateRow(width: 160)
        addGateRow(width: 200)
        addGateRow(width: 140, showsRule: false)
    }

    private func addDotRow(indent: CGFloat, width: CGFloat) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: indent, bottom: 8, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(SkeletonBarView(width: 9, height: 9, radius: 4.5))
        row.addArrangedSubview(SkeletonBarView(width: width, height: 9))
        stackView.addArrangedSubview(row)
    }

    private func addGateRow(width: CGFloat, showsRule: Bool = true) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(SkeletonBarView(width: 16, height: 16, radius: 5))
        row.addArrangedSubview(SkeletonBarView(width: width, height: 9))
        stackView.addArrangedSubview(row)
        if showsRule {
            addBar(width: 310, height: 1, color: AppPalette.lineSoftSubtle)
        }
    }

    private func addBar(
        width: CGFloat,
        height: CGFloat,
        color: NSColor = AppPalette.controlFill,
        top: CGFloat = 0,
        bottom: CGFloat = 0
    ) {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        let bar = SkeletonBarView(width: width, height: height, color: color)
        wrapper.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: top),
            bar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            bar.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -bottom),
        ])
        stackView.addArrangedSubview(wrapper)
    }
}

private final class SkeletonBarView: NSView {
    init(width: CGFloat, height: CGFloat, radius: CGFloat = 3, color: NSColor = AppPalette.controlFill) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = radius
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            layer?.removeAnimation(forKey: "questmaster.skeletonPulse")
        } else {
            startPulse()
        }
    }

    private func startPulse() {
        guard layer?.animation(forKey: "questmaster.skeletonPulse") == nil else {
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.45
        animation.toValue = 1
        animation.duration = 1.6
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "questmaster.skeletonPulse")
    }
}
