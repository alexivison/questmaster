import AppKit
import QuestmasterCore

@MainActor
final class NewSessionModalController: NSObject {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private var model: NewSessionFormModel
    private let mutationClient: ServeMutationSending
    private let directoryClient: ServeDirectorySuggesting?
    private let onSuccess: (String?) -> Void
    private let panel: NSPanel
    private let content = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let roleControl = NSSegmentedControl(labels: ["Standalone", "Master"], trackingMode: .selectOne, target: nil, action: nil)
    private let pathField = NSTextField(string: "")
    private let titleField = NSTextField(string: "")
    private let agentSelect = NewSessionSelectView()
    private let colorSelect = NewSessionSelectView()
    private let questSelect = NewSessionSelectView()
    private let promptScroll = NSScrollView()
    private let promptView = NSTextView()
    private let suggestionsScroll = NSScrollView()
    private let suggestionsDocument = NSView()
    private let suggestionsBox = NSStackView()
    private let errorRow = NSView()
    private let errorLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private var eventMonitor: Any?
    private var errorRowHeightConstraint: NSLayoutConstraint?
    private var pathSuggestions: [String] = []
    private var highlightedSuggestionIndex = 0
    private var suggestionRequestID = 0
    private var suggestionsHeightConstraint: NSLayoutConstraint?
    private let maxVisibleSuggestionRows = 4
    private let suggestionRowHeight: CGFloat = 24
    private let suggestionHintHeight: CGFloat = 23

    init(
        role: NewSessionRole,
        initialPath: String,
        quests: [NewSessionQuestOption],
        mutationClient: ServeMutationSending,
        directoryClient: ServeDirectorySuggesting?,
        onSuccess: @escaping (String?) -> Void
    ) {
        model = NewSessionFormModel(role: role, initialPath: initialPath, quests: quests)
        self.mutationClient = mutationClient
        self.directoryClient = directoryClient
        self.onSuccess = onSuccess
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 580),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        buildView()
        render()
    }

    func show(relativeTo parent: NSWindow?) {
        if let parent {
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2
            ))
            parent.addChildWindow(panel, ordered: .above)
        } else {
            panel.center()
        }
        installEventMonitor()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(pathField)
        requestPathSuggestions(recentsOnly: false)
    }

    func close() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = content
    }

    private func buildView() {
        content.wantsLayer = true
        content.layer?.backgroundColor = AppPalette.panel.cgColor
        content.layer?.borderColor = AppPalette.line.cgColor
        content.layer?.borderWidth = 1
        content.layer?.cornerRadius = 12
        content.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        root.addArrangedSubview(headerView())
        root.addArrangedSubview(divider())
        root.addArrangedSubview(pathRow())
        root.addArrangedSubview(textRow(label: "Title:", field: titleField, placeholder: "optional, auto-generated if blank"))
        root.addArrangedSubview(selectRow(label: "Agent:", select: agentSelect, note: "primary agent for the session", focus: .agent))
        root.addArrangedSubview(selectRow(label: "Color:", select: colorSelect, note: "the session display color", focus: .color))
        root.addArrangedSubview(selectRow(label: "Quest:", select: questSelect, note: "none, or attach an active quest on spawn", focus: .quest))
        root.addArrangedSubview(promptRow())
        root.addArrangedSubview(errorView())
        root.addArrangedSubview(NSView())
        root.addArrangedSubview(divider())
        root.addArrangedSubview(footerView())
    }

    private func errorView() -> NSView {
        errorRow.translatesAutoresizingMaskIntoConstraints = false
        errorRowHeightConstraint = errorRow.heightAnchor.constraint(equalToConstant: 0)
        errorRowHeightConstraint?.isActive = true
        errorLabel.font = AppFonts.monoSmall
        errorLabel.textColor = AppPalette.deleted
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 2
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorRow.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.topAnchor.constraint(equalTo: errorRow.topAnchor, constant: 6),
            errorLabel.leadingAnchor.constraint(equalTo: errorRow.leadingAnchor, constant: 18),
            errorLabel.trailingAnchor.constraint(equalTo: errorRow.trailingAnchor, constant: -18),
            errorLabel.bottomAnchor.constraint(equalTo: errorRow.bottomAnchor, constant: -6),
        ])
        return errorRow
    }

    private func headerView() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 58).isActive = true

        titleLabel.font = NSFont.systemFont(ofSize: 15.5, weight: .semibold)
        titleLabel.textColor = AppPalette.bright
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        roleControl.segmentStyle = .texturedRounded
        roleControl.target = self
        roleControl.action = #selector(roleChanged(_:))
        roleControl.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleLabel)
        view.addSubview(roleControl)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            roleControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            roleControl.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            roleControl.widthAnchor.constraint(equalToConstant: 184),
        ])
        return view
    }

    private func divider() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = AppPalette.line.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func pathRow() -> NSView {
        let row = formRow(label: "Path:", topAligned: true)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.fieldContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: row.fieldContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: row.fieldContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.fieldContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: row.fieldContainer.bottomAnchor),
        ])

        configure(field: pathField, placeholder: "/path/to/project")
        pathField.delegate = self
        stack.addArrangedSubview(pathField)

        configureSuggestionsScroll()
        stack.addArrangedSubview(suggestionsScroll)

        return row.view
    }

    private func configureSuggestionsScroll() {
        suggestionsScroll.drawsBackground = false
        suggestionsScroll.hasVerticalScroller = true
        suggestionsScroll.autohidesScrollers = true
        suggestionsScroll.wantsLayer = true
        suggestionsScroll.layer?.backgroundColor = AppPalette.panelAlt.cgColor
        suggestionsScroll.layer?.borderColor = AppPalette.line.cgColor
        suggestionsScroll.layer?.borderWidth = 1
        suggestionsScroll.layer?.cornerRadius = 7
        suggestionsScroll.translatesAutoresizingMaskIntoConstraints = false

        suggestionsDocument.translatesAutoresizingMaskIntoConstraints = false
        suggestionsBox.orientation = .vertical
        suggestionsBox.alignment = .width
        suggestionsBox.spacing = 0
        suggestionsBox.translatesAutoresizingMaskIntoConstraints = false
        suggestionsDocument.addSubview(suggestionsBox)
        suggestionsScroll.documentView = suggestionsDocument

        let height = suggestionsScroll.heightAnchor.constraint(equalToConstant: 0)
        suggestionsHeightConstraint = height
        NSLayoutConstraint.activate([
            height,
            suggestionsDocument.leadingAnchor.constraint(equalTo: suggestionsScroll.contentView.leadingAnchor),
            suggestionsDocument.trailingAnchor.constraint(equalTo: suggestionsScroll.contentView.trailingAnchor),
            suggestionsDocument.topAnchor.constraint(equalTo: suggestionsScroll.contentView.topAnchor),
            suggestionsDocument.widthAnchor.constraint(equalTo: suggestionsScroll.contentView.widthAnchor),
            suggestionsBox.topAnchor.constraint(equalTo: suggestionsDocument.topAnchor),
            suggestionsBox.leadingAnchor.constraint(equalTo: suggestionsDocument.leadingAnchor),
            suggestionsBox.trailingAnchor.constraint(equalTo: suggestionsDocument.trailingAnchor),
            suggestionsBox.bottomAnchor.constraint(equalTo: suggestionsDocument.bottomAnchor),
        ])
        suggestionsScroll.isHidden = true
    }

    private func textRow(label: String, field: NSTextField, placeholder: String) -> NSView {
        let row = formRow(label: label)
        configure(field: field, placeholder: placeholder)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        row.fieldContainer.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: row.fieldContainer.topAnchor),
            field.leadingAnchor.constraint(equalTo: row.fieldContainer.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: row.fieldContainer.trailingAnchor),
            field.bottomAnchor.constraint(equalTo: row.fieldContainer.bottomAnchor),
        ])
        return row.view
    }

    private func selectRow(label: String, select: NewSessionSelectView, note: String, focus: NewSessionField) -> NSView {
        let row = formRow(label: label)
        select.onFocus = { [weak self] in
            self?.model.focusedField = focus
            self?.render()
        }
        select.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(select)
        select.widthAnchor.constraint(equalToConstant: 164).isActive = true

        let noteLabel = NSTextField(labelWithString: note)
        noteLabel.font = NSFont.systemFont(ofSize: 11.5)
        noteLabel.textColor = AppPalette.dim
        stack.addArrangedSubview(noteLabel)

        row.fieldContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: row.fieldContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: row.fieldContainer.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: row.fieldContainer.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: row.fieldContainer.bottomAnchor),
        ])
        return row.view
    }

    private func promptRow() -> NSView {
        let row = formRow(label: "Prompt:", topAligned: true)
        configurePromptView()
        row.fieldContainer.addSubview(promptScroll)
        NSLayoutConstraint.activate([
            promptScroll.topAnchor.constraint(equalTo: row.fieldContainer.topAnchor),
            promptScroll.leadingAnchor.constraint(equalTo: row.fieldContainer.leadingAnchor),
            promptScroll.trailingAnchor.constraint(equalTo: row.fieldContainer.trailingAnchor),
            promptScroll.bottomAnchor.constraint(equalTo: row.fieldContainer.bottomAnchor),
            promptScroll.heightAnchor.constraint(equalToConstant: 76),
        ])
        return row.view
    }

    private func footerView() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: 42).isActive = true
        footerLabel.font = AppFonts.monoSmall
        footerLabel.textColor = AppPalette.dim
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerLabel)
        NSLayoutConstraint.activate([
            footerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -18),
            footerLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    private func formRow(label: String, topAligned: Bool = false) -> (view: NSView, fieldContainer: NSView) {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: topAligned ? 52 : 48).isActive = true

        let labelView = NSTextField(labelWithString: label)
        labelView.font = AppFonts.monoSmall
        labelView.textColor = AppPalette.dim
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 74).isActive = true

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(labelView)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            labelView.topAnchor.constraint(equalTo: view.topAnchor, constant: topAligned ? 20 : 17),
            container.topAnchor.constraint(equalTo: view.topAnchor, constant: 11),
            container.leadingAnchor.constraint(equalTo: labelView.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
        ])
        return (view, container)
    }

    private func configure(field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13.5)
        field.textColor = AppPalette.text
        field.backgroundColor = AppPalette.panelAlt
        field.isBezeled = false
        field.isBordered = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.backgroundColor = AppPalette.panelAlt.cgColor
        field.layer?.borderColor = AppPalette.line.cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 7
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    private func configurePromptView() {
        promptScroll.drawsBackground = false
        promptScroll.hasVerticalScroller = true
        promptScroll.autohidesScrollers = true
        promptScroll.wantsLayer = true
        promptScroll.layer?.backgroundColor = AppPalette.panelAlt.cgColor
        promptScroll.layer?.borderColor = AppPalette.line.cgColor
        promptScroll.layer?.borderWidth = 1
        promptScroll.layer?.cornerRadius = 7
        promptScroll.translatesAutoresizingMaskIntoConstraints = false

        promptView.delegate = self
        promptView.isRichText = false
        promptView.importsGraphics = false
        promptView.font = NSFont.systemFont(ofSize: 13.5)
        promptView.textColor = AppPalette.text
        promptView.backgroundColor = AppPalette.panelAlt
        promptView.insertionPointColor = AppPalette.warn
        promptView.textContainerInset = NSSize(width: 8, height: 7)
        promptView.isVerticallyResizable = true
        promptView.isHorizontallyResizable = false
        promptView.textContainer?.widthTracksTextView = true
        promptView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        promptScroll.documentView = promptView
    }

    @objc private func roleChanged(_ sender: NSSegmentedControl) {
        model.setRole(sender.selectedSegment == 1 ? .master : .standalone)
        render()
    }

    private func render() {
        titleLabel.stringValue = model.headerTitle
        roleControl.selectedSegment = model.role == .master ? 1 : 0
        roleControl.isEnabled = !model.submitting
        pathField.stringValue = model.path
        titleField.stringValue = model.title
        promptView.string = model.prompt
        pathField.isEnabled = !model.submitting
        titleField.isEnabled = !model.submitting
        promptView.isEditable = !model.submitting

        agentSelect.update(
            title: model.selectedAgent,
            dotColor: AppPalette.agent(model.selectedAgent),
            swatchColor: nil,
            focused: model.focusedField == .agent
        )
        colorSelect.update(
            title: model.selectedColor,
            dotColor: nil,
            swatchColor: AppPalette.displayColorNames[model.selectedColor] ?? AppPalette.accent,
            focused: model.focusedField == .color
        )
        questSelect.update(
            title: model.selectedQuestLabel,
            dotColor: nil,
            swatchColor: nil,
            focused: model.focusedField == .quest
        )
        agentSelect.isControlEnabled = !model.submitting
        colorSelect.isControlEnabled = !model.submitting
        questSelect.isControlEnabled = !model.submitting

        let error = model.errorMessage ?? ""
        errorLabel.stringValue = error
        errorRow.isHidden = error.isEmpty
        errorRowHeightConstraint?.constant = error.isEmpty ? 0 : 46
        footerLabel.stringValue = footerText()
        renderSuggestions()
    }

    private func renderSuggestions() {
        suggestionsBox.arrangedSubviews.forEach { view in
            suggestionsBox.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard model.focusedField == .path, !pathSuggestions.isEmpty else {
            suggestionsScroll.isHidden = true
            suggestionsHeightConstraint?.constant = 0
            return
        }
        suggestionsScroll.isHidden = false
        for (index, suggestion) in pathSuggestions.enumerated() {
            let label = NSTextField(labelWithString: suggestion)
            label.font = AppFonts.monoSmall
            label.textColor = index == highlightedSuggestionIndex ? AppPalette.bright : AppPalette.muted
            label.backgroundColor = index == highlightedSuggestionIndex ? AppPalette.selection : .clear
            label.drawsBackground = index == highlightedSuggestionIndex
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            label.heightAnchor.constraint(equalToConstant: 24).isActive = true
            suggestionsBox.addArrangedSubview(label)
        }
        let hint = NSTextField(labelWithString: "zoxide-ranked · tab to complete · ^r for recents")
        hint.font = AppFonts.monoSmall
        hint.textColor = AppPalette.dim
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.heightAnchor.constraint(equalToConstant: 23).isActive = true
        suggestionsBox.addArrangedSubview(hint)
        let visibleRows = min(pathSuggestions.count, maxVisibleSuggestionRows)
        suggestionsHeightConstraint?.constant = CGFloat(visibleRows) * suggestionRowHeight + suggestionHintHeight
    }

    private func footerText() -> String {
        if model.submitting {
            return "Creating session…"
        }
        if model.focusedField == .prompt {
            return Keymap.NewSession.promptFooterText
        }
        return Keymap.NewSession.defaultFooterText
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard panel.isKeyWindow else {
            return false
        }
        if event.modifierFlags.contains(.command) {
            return false
        }
        if model.submitting {
            return true
        }

        let chars = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = flags.contains(.control)
        if Keymap.NewSession.cancel.matches(event.keyCode) {
            close()
            return true
        }
        if control, Keymap.NewSession.nextField.matches(chars) {
            model.handle(.controlJ)
            focusCurrentField()
            return true
        }
        if control, Keymap.NewSession.previousField.matches(chars) {
            model.handle(.controlK)
            focusCurrentField()
            return true
        }
        if control, Keymap.NewSession.recentPaths.matches(chars), model.focusedField == .path {
            requestPathSuggestions(recentsOnly: true)
            return true
        }
        if control, Keymap.NewSession.createFromPrompt.matches(chars) {
            if model.creationRequested(by: .controlS) {
                submit()
                return true
            }
            return false
        }
        if Keymap.NewSession.completePath.matches(event.keyCode) {
            if model.focusedField == .path {
                completePath()
                return true
            }
            return false
        }
        if Keymap.NewSession.selectLeft.matches(event.keyCode) {
            if model.isSelectFocused {
                model.handle(.left)
                render()
                return true
            }
            return false
        }
        if Keymap.NewSession.selectRight.matches(event.keyCode) {
            if model.isSelectFocused {
                model.handle(.right)
                render()
                return true
            }
            return false
        }
        if flags.subtracting(.shift).isEmpty, model.handleSelectShortcut(chars) {
            render()
            return true
        }
        if Keymap.NewSession.create.matches(chars) {
            if model.creationRequested(by: .enter) {
                submit()
                return true
            }
            return false
        }
        return false
    }

    private func focusCurrentField() {
        render()
        switch model.focusedField {
        case .path:
            panel.makeFirstResponder(pathField)
            requestPathSuggestions(recentsOnly: false)
        case .title:
            panel.makeFirstResponder(titleField)
        case .agent:
            panel.makeFirstResponder(agentSelect)
        case .color:
            panel.makeFirstResponder(colorSelect)
        case .quest:
            panel.makeFirstResponder(questSelect)
        case .prompt:
            panel.makeFirstResponder(promptView)
        }
    }

    private func requestPathSuggestions(recentsOnly: Bool) {
        let query = model.path
        suggestionRequestID += 1
        let requestID = suggestionRequestID
        directoryClient?.suggestDirectories(query: query) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.suggestionRequestID == requestID else {
                    return
                }
                switch result {
                case .success(let response):
                    let values = recentsOnly ? response.recents : response.suggestions
                    self.pathSuggestions = self.nonEmptyPathSuggestions(values.isEmpty ? response.recents : values, query: query)
                    self.highlightedSuggestionIndex = 0
                case .failure:
                    self.pathSuggestions = self.nonEmptyPathSuggestions([], query: query)
                    self.highlightedSuggestionIndex = 0
                }
                self.renderSuggestions()
            }
        }
    }

    private func nonEmptyPathSuggestions(_ values: [String], query: String) -> [String] {
        if !values.isEmpty {
            return values
        }
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? [] : [clean]
    }

    private func completePath() {
        if !pathSuggestions.isEmpty, pathSuggestions.indices.contains(highlightedSuggestionIndex) {
            model.path = pathSuggestions[highlightedSuggestionIndex]
            pathField.stringValue = model.path
            requestPathSuggestions(recentsOnly: false)
            return
        }
        let completed = localPathCompletion(model.path)
        if completed != model.path {
            model.path = completed
            pathField.stringValue = completed
            requestPathSuggestions(recentsOnly: false)
        }
    }

    private func localPathCompletion(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let directory: String
        let partial: String
        if expanded.hasSuffix("/") || expanded.isEmpty {
            directory = expanded.isEmpty ? "." : expanded
            partial = ""
        } else {
            directory = (expanded as NSString).deletingLastPathComponent
            partial = (expanded as NSString).lastPathComponent
        }
        guard let names = (try? FileManager.default.contentsOfDirectory(atPath: directory))?
            .filter({ name in
                var isDir: ObjCBool = false
                return name.hasPrefix(partial)
                    && FileManager.default.fileExists(atPath: URL(fileURLWithPath: directory).appendingPathComponent(name).path, isDirectory: &isDir)
                    && isDir.boolValue
            })
            .sorted(), !names.isEmpty else {
            return raw
        }
        let prefix = commonPrefix(names)
        let chosen = names.count == 1 ? names[0] : prefix
        guard !chosen.isEmpty else {
            return raw
        }
        return URL(fileURLWithPath: directory).appendingPathComponent(chosen).path + (names.count == 1 ? "/" : "")
    }

    private func submit() {
        model.path = pathField.stringValue
        model.title = titleField.stringValue
        model.prompt = promptView.string
        guard let payload = model.submitPayload() else {
            pathSuggestions = []
            render()
            return
        }
        pathSuggestions = []
        model.setSubmitting(true)
        render()

        do {
            let request = try ServeMutationRequests.start(
                role: payload.role,
                title: payload.title,
                cwd: payload.path,
                agent: payload.agent,
                color: payload.color,
                questID: payload.questID,
                prompt: payload.prompt
            )
            mutationClient.send(request) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else {
                        return
                    }
                    switch result {
                    case .success(let ack):
                        self.close()
                        self.onSuccess(ack.sessionID)
                    case .failure(let error):
                        self.pathSuggestions = []
                        self.model.setSubmitting(false)
                        self.model.setError(error.localizedDescription)
                        self.render()
                    }
                }
            }
        } catch {
            pathSuggestions = []
            model.setSubmitting(false)
            model.setError(error.localizedDescription)
            render()
        }
    }

}

extension NewSessionModalController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === pathField {
            model.focusedField = .path
            requestPathSuggestions(recentsOnly: false)
        } else if field === titleField {
            model.focusedField = .title
        }
        render()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === pathField {
            model.path = field.stringValue
            requestPathSuggestions(recentsOnly: false)
        } else if field === titleField {
            model.title = field.stringValue
        }
    }
}

extension NewSessionModalController: NSTextViewDelegate {
    func textDidBeginEditing(_ notification: Notification) {
        model.focusedField = .prompt
        render()
    }

    func textDidChange(_ notification: Notification) {
        model.prompt = promptView.string
    }
}

private final class NewSessionSelectView: NSView {
    var onFocus: (() -> Void)?
    var isControlEnabled = true {
        didSet {
            alphaValue = isControlEnabled ? 1 : 0.55
        }
    }
    private let left = NSTextField(labelWithString: "‹")
    private let right = NSTextField(labelWithString: "›")
    private let dot = NSTextField(labelWithString: "●")
    private let swatch = NSView()
    private let title = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var swatchWidthConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = AppPalette.panelAlt.cgColor
        layer?.borderColor = AppPalette.line.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 7

        left.font = AppFonts.mono
        right.font = AppFonts.mono
        left.textColor = AppPalette.dim
        right.textColor = AppPalette.dim
        dot.font = AppFonts.monoSmall
        title.font = NSFont.systemFont(ofSize: 13.5)
        title.textColor = AppPalette.text
        title.lineBreakMode = .byTruncatingTail
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.setContentHuggingPriority(.defaultLow, for: .horizontal)
        swatch.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        swatchWidthConstraint = swatch.widthAnchor.constraint(equalToConstant: 11)
        NSLayoutConstraint.activate([
            swatchWidthConstraint!,
            swatch.heightAnchor.constraint(equalToConstant: 13),
        ])

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(left)
        stack.addArrangedSubview(dot)
        stack.addArrangedSubview(swatch)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(right)
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isControlEnabled else {
            return
        }
        window?.makeFirstResponder(self)
    }

    func update(title value: String, dotColor: NSColor?, swatchColor: NSColor?, focused: Bool) {
        let showsColorBar = swatchColor != nil
        title.stringValue = showsColorBar ? "" : value
        title.isHidden = showsColorBar
        dot.isHidden = dotColor == nil
        dot.textColor = dotColor ?? AppPalette.dim
        swatch.isHidden = swatchColor == nil
        swatchWidthConstraint?.isActive = !showsColorBar
        swatchWidthConstraint?.constant = 11
        swatch.layer?.backgroundColor = swatchColor?.cgColor
        layer?.borderColor = (focused ? AppPalette.warn : AppPalette.line).cgColor
        layer?.borderWidth = focused ? 2 : 1
    }
}

private func commonPrefix(_ values: [String]) -> String {
    guard var prefix = values.first else {
        return ""
    }
    for value in values.dropFirst() {
        while !value.hasPrefix(prefix) {
            prefix.removeLast()
            if prefix.isEmpty {
                return ""
            }
        }
    }
    return prefix
}
