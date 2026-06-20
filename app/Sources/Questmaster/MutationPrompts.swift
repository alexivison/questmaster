import AppKit

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

}
