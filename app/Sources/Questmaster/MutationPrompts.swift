import AppKit

struct SpawnMutationInput {
    var title: String
    var cwd: String
    var prompt: String
    var agent: String
    var questID: String
}

enum MutationPrompts {
    static func text(title: String, placeholder: String, defaultValue: String = "") -> String? {
        let field = NSTextField(string: defaultValue)
        field.placeholderString = placeholder
        field.font = AppFonts.mono
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)

        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func confirmDelete(sessionID: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete \(sessionID)"
        alert.informativeText = "This removes the session and its runtime files."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func spawn(defaultCwd: String, defaultQuestID: String) -> SpawnMutationInput? {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 168)

        let title = field(placeholder: "title", value: "")
        let cwd = field(placeholder: "cwd", value: defaultCwd)
        let prompt = field(placeholder: "prompt", value: "")
        let agent = field(placeholder: "agent", value: "")
        let quest = field(placeholder: "quest", value: defaultQuestID)

        for (label, control) in [
            ("Title", title),
            ("Cwd", cwd),
            ("Prompt", prompt),
            ("Agent", agent),
            ("Quest", quest),
        ] {
            stack.addArrangedSubview(row(label: label, control: control))
        }

        let alert = NSAlert()
        alert.messageText = "Spawn worker"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Spawn")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }
        return SpawnMutationInput(
            title: title.stringValue,
            cwd: cwd.stringValue,
            prompt: prompt.stringValue,
            agent: agent.stringValue,
            questID: quest.stringValue
        )
    }

    private static func field(placeholder: String, value: String) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.font = AppFonts.mono
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return field
    }

    private static func row(label: String, control: NSView) -> NSView {
        let title = NSTextField(labelWithString: label)
        title.font = AppFonts.monoSmall
        title.textColor = AppPalette.dim
        title.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 58).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(title)
        row.addArrangedSubview(control)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}
