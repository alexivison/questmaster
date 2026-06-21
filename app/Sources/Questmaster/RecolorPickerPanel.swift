import AppKit
import QuestmasterCore

struct RecolorMutationChoice {
    let request: ServeMutationRequest
    let label: String
}

extension MutationPrompts {
    static func recolor(targetTitle: String, initialState: TrackerRecolorPickerState) -> RecolorMutationChoice? {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = initialState.scope == .repo ? "Recolor Repo" : "Recolor Session"
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = AppPalette.panel

        var choice: RecolorMutationChoice?
        let content = RecolorPickerContentView(targetTitle: targetTitle, initialState: initialState)
        content.onChoose = { picked in
            choice = picked
            NSApp.stopModal()
            panel.close()
        }
        content.onCancel = {
            NSApp.stopModal()
            panel.close()
        }
        panel.contentView = content
        panel.center()

        NSApp.runModal(for: panel)
        panel.close()
        return choice
    }
}

private final class RecolorPickerContentView: NSView {
    var onChoose: ((RecolorMutationChoice) -> Void)?
    var onCancel: (() -> Void)?

    private var state: TrackerRecolorPickerState
    private let targetTitle: String
    private let errorLabel = NSTextField(labelWithString: "")
    private var swatchButtons: [RecolorSwatchButton] = []

    init(targetTitle: String, initialState: TrackerRecolorPickerState) {
        self.targetTitle = targetTitle
        self.state = initialState
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 360))
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panel.cgColor
        build()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        let title = NSTextField(labelWithString: targetTitle)
        title.font = AppFonts.bodyBold
        title.textColor = AppPalette.bright
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(title)
        title.widthAnchor.constraint(equalToConstant: 298).isActive = true

        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(grid)

        let swatches = TrackerRecolorPickerState.swatches
        for rowStart in stride(from: 0, to: swatches.count, by: 2) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            grid.addArrangedSubview(row)

            for index in rowStart..<min(rowStart + 2, swatches.count) {
                let swatch = swatches[index]
                let button = RecolorSwatchButton(
                    swatch: swatch,
                    color: AppPalette.displayColorNames[swatch.name] ?? AppPalette.accent
                )
                button.target = self
                button.action = #selector(swatchPicked(_:))
                button.translatesAutoresizingMaskIntoConstraints = false
                button.widthAnchor.constraint(equalToConstant: 142).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                swatchButtons.append(button)
                row.addArrangedSubview(button)
            }
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearPicked))
        clear.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPicked))
        cancel.bezelStyle = .rounded
        footer.addArrangedSubview(clear)
        footer.addArrangedSubview(cancel)
        root.addArrangedSubview(footer)

        errorLabel.font = AppFonts.monoSmall
        errorLabel.textColor = AppPalette.deleted
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(errorLabel)
        errorLabel.widthAnchor.constraint(equalToConstant: 298).isActive = true

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    @objc private func swatchPicked(_ sender: RecolorSwatchButton) {
        finish(color: sender.swatch.name)
    }

    @objc private func clearPicked() {
        finish(color: "")
    }

    @objc private func cancelPicked() {
        onCancel?()
    }

    private func refresh() {
        for button in swatchButtons {
            button.selectedSwatch = button.swatch.name == state.selectedSwatch?.name
        }
    }

    private func finish(color: String) {
        do {
            let request = try state.request(color: color)
            onChoose?(RecolorMutationChoice(request: request, label: mutationLabel(color: color)))
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
        }
    }

    private func mutationLabel(color: String) -> String {
        let action = color.isEmpty ? "clear" : "recolor"
        switch state.scope {
        case .session:
            return "\(action) session \(state.target.sessionID)"
        case .repo:
            return "\(action) repo color"
        }
    }
}

private final class RecolorSwatchButton: NSButton {
    let swatch: TrackerColorSwatch
    let swatchColor: NSColor

    var selectedSwatch = false {
        didSet {
            needsDisplay = true
        }
    }

    init(swatch: TrackerColorSwatch, color: NSColor) {
        self.swatch = swatch
        self.swatchColor = color
        super.init(frame: .zero)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        wantsLayer = true
        toolTip = swatch.cssVariable
        setAccessibilityLabel(swatch.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let background = selectedSwatch ? AppPalette.selection : AppPalette.panelAlt
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        (selectedSwatch ? AppPalette.warn : AppPalette.line).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        border.lineWidth = selectedSwatch ? 1.5 : 1
        border.stroke()

        swatchColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 10, y: 8, width: 12, height: 12), xRadius: 2, yRadius: 2).fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: AppFonts.monoSmall,
            .foregroundColor: selectedSwatch ? AppPalette.bright : AppPalette.text,
        ]
        (swatch.name as NSString).draw(
            in: NSRect(x: 30, y: 6, width: bounds.width - 38, height: 16),
            withAttributes: attrs
        )
    }
}
