import Foundation
import QuestmasterCore

struct TmuxSettingsModelTests {
    static func run() throws {
        let status = try TmuxConfigStatus.decodeResponse(fixture("tmux_config_response_envelope.json"))
        try expect(status.config == "/tmp/example/tmux/questmaster.conf", "config path should come from the daemon")
        try expect(status.enforced == "/tmp/example/tmux/enforced.questmaster.conf", "enforced path should match the label")
        try expect(status.effectiveLabel == "questmaster", "effective label should come from the daemon")
        var model = TmuxSettingsModel(status: status)
        try expect(model.canReload, "a running server can reload")
        try expect(!model.canRestart && model.restartCaption.contains("1 session"), "sessions should block restart with a reason")
        model.moveFocus(1)
        try expect(model.focusedAction == .reveal, "j should move to the next action")
        model.moveFocus(-1)
        try expect(model.focusedAction == .openEditor, "k should move to the previous action")
        try expect(model.showsEditedSinceStart, "edited flag should follow status")
        try expect(!model.showsEnforcedPending, "pending flag should follow status")

        var empty = status
        empty.sessions = 0
        empty.enforcedPending = true
        empty.builtinTemplateVersion = empty.templateVersion + 1
        model = TmuxSettingsModel(status: empty)
        try expect(model.canRestart, "a running empty server can restart")
        try expect(model.showsEnforcedPending, "pending flag should follow status")
        try expect(model.showsNewerTemplate, "a newer built-in template should be announced")

        var stopped = empty
        stopped.running = false
        model = TmuxSettingsModel(status: stopped)
        try expect(!model.canReload && !model.canRestart, "a stopped server has no live actions")
        try expect(model.serverCaption.contains("next session start"), "stopped state should explain when config loads")
        try expect(model.restartCaption.contains("not running"), "restart should explain why it is disabled")

        let checked = try TmuxConfigCheck.decodeResponse(fixture("tmux_config_check_response_envelope.json"))
        try expect(checked.ok && checked.errors.isEmpty, "successful check should decode")
        let reloaded = try TmuxConfigReload.decodeResponse(fixture("tmux_config_reload_response_envelope.json"))
        try expect(reloaded.running && reloaded.errors.isEmpty, "reload fixture should decode")
        let restarted = try TmuxServerRestart.decodeResponse(fixture("tmux_server_restart_response_envelope.json"))
        try expect(restarted.refused && restarted.sessions == 1, "restart refusal should decode")
        let failed = try TmuxConfigCheck.decodeResponse(Data(#"{"protocol_version":3,"type":"response","ok":true,"topic":"tmux.config.check","data":{"ok":false,"errors":["/tmp/example.conf:7: unknown option"],"effective_label":"questmaster"}}"#.utf8))
        try expect(!failed.ok && failed.errors == ["/tmp/example.conf:7: unknown option"], "file and line errors should survive decoding")
        try expect((try? TmuxConfigStatus.decodeResponse(Data(#"{"data":{"running":"yes"}}"#.utf8))) == nil, "invalid status should fail decoding")
        try expect((try? TmuxConfigCheck.decodeResponse(Data(#"{"data":{"ok":false,"errors":"bad"}}"#.utf8))) == nil, "invalid check should fail decoding")
        print("TmuxSettingsModelTests: all tests passed")
    }

    private static func fixture(_ name: String) throws -> Data {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let file = url.appendingPathComponent("internal/serve/testdata/\(name)")
            if FileManager.default.fileExists(atPath: file.path) { return try Data(contentsOf: file) }
            url.deleteLastPathComponent()
        }
        throw Failure("tmux config fixture missing")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
