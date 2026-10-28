import Foundation
import Darwin

enum QuestmasterLogicTests {
    static func main() throws {
        timed("TrackerRendererTests") { TrackerRendererTests.run() }
        timed("TrackerPlateVariantTests") { TrackerPlateVariantTests.run() }
        timed("TrackerShellSectionTests") { TrackerShellSectionTests.run() }
        timed("TrackerAttachedDotTests") { TrackerAttachedDotTests.run() }
        timed("FooterBandTests") { FooterBandTests.run() }
        timed("TrackerRecolorLogicTests") { TrackerRecolorLogicTests.run() }
        timed("TrackerCommandStateTests") { TrackerCommandStateTests.run() }
        timed("MutationRequestTests") { MutationRequestTests.run() }
        timed("NavigationLogicTests") { NavigationLogicTests.run() }
        timed("ShellSplitLayoutTests") { ShellSplitLayoutTests.run() }
        timed("TerminalCellSnappingTests") { TerminalCellSnappingTests.run() }
        timed("GhosttyGapDerivationTests") { GhosttyGapDerivationTests.run() }
        timed("TrackerHeaderAlignmentTests") { TrackerHeaderAlignmentTests.run() }
        timed("DockWidthPreferenceTests") { DockWidthPreferenceTests.run() }
        timed("ServeRecoveryPolicyTests") { ServeRecoveryPolicyTests.run() }
        timed("DaemonConnectionTests") { DaemonConnectionTests.run() }
        timed("NewSessionLogicTests") { NewSessionLogicTests.run() }
        timed("SessionClassLogicTests") { SessionClassLogicTests.run() }
        timed("ColorFieldTests") { ColorFieldTests.run() }
        timed("PickerFieldKeyTests") { PickerFieldKeyTests.run() }
        timed("FilterFieldKeyTests") { FilterFieldKeyTests.run() }
        timed("RoleDefaultsLogicTests") { RoleDefaultsLogicTests.run() }
        timed("NewTerminalLogicTests") { NewTerminalLogicTests.run() }
        timed("DestructiveConfirmationTests") { DestructiveConfirmationTests.run() }
        timed("KeymapTests") { KeymapTests.run() }
        timed("ListKeysTests") { ListKeysTests.run() }
        timed("ModalKeysTests") { ModalKeysTests.run() }
        timed("TrackerSessionShortcutsTests") { TrackerSessionShortcutsTests.run() }
        timed("RuntimeDecoderTests") { RuntimeDecoderTests.run() }
        timed("ContractFixtureTests") { ContractFixtureTests.run() }
        timed("PullRequestModelsTests") { PullRequestModelsTests.run() }
        timed("PullRequestStoreTests") { PullRequestStoreTests.run() }
        timed("RuntimeStoreTests") { RuntimeStoreTests.run() }
        timed("NavigationStoreTests") { NavigationStoreTests.run() }
        timed("DockStateTests") { DockStateTests.run() }
        timed("DisplayClassificationTests") { DisplayClassificationTests.run() }
        timed("ArtifactCoreTests") { ArtifactCoreTests.run() }
        timed("QuestCoreTests") { QuestCoreTests.run() }
        timed("ShellChromeTests") { ShellChromeTests.run() }
        timed("CaffeineStateTests") { CaffeineStateTests.run() }
        timed("GhosttyConfigParserTests") { GhosttyConfigParserTests.run() }
        timed("TerminalDetachSignalTests") { TerminalDetachSignalTests.run() }
        timed("WorkerChatTests") { WorkerChatTests.run() }
        timed("WorkerChatScrollTests") { WorkerChatScrollTests.run() }
        timed("WorkerLogFilterTests") { WorkerLogFilterTests.run() }
        timed("TrackerCastTests") { TrackerCastTests.run() }
        timed("ModalCommandRoutingTests") { ModalCommandRoutingTests.run() }
        timed("InteractionLookTests") { InteractionLookTests.run() }
        timed("StateRulesScanTests") { StateRulesScanTests.run() }
        timed("SpacingRulesScanTests") { SpacingRulesScanTests.run() }
        timed("MotionTests") { MotionTests.run() }
        timed("MotionRulesScanTests") { MotionRulesScanTests.run() }

        let packageRoot = try findPackageRoot()
        let result = try run(
            executable: "/usr/bin/env",
            arguments: [
                "swift",
                "run",
                "--package-path",
                packageRoot.path,
                "Questmaster",
                "--run-logic-tests",
            ]
        )

        try expect(result.status == 0, "logic tests exited \(result.status)\n\(result.output)")
        try expect(
            !result.output.contains("Questmaster self-tests failed"),
            "logic tests reported a failure\n\(result.output)"
        )
        // Require a non-zero count ([1-9]\d*) so an emptied case table can't pass vacuously.
        try expect(
            result.output.range(
                of: #"Questmaster self-tests: [1-9]\d* passed"#,
                options: .regularExpression
            ) != nil,
            "logic test pass line missing or reported zero tests\n\(result.output)"
        )
        print("QuestmasterLogicTests: process runner passed")
    }

    private static func timed<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let started = Date()
        print("RUN \(name)")
        fflush(stdout)
        let watchdog = DispatchWorkItem {
            fputs("TIMEOUT \(name) after 120 seconds\n", stderr)
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
        defer { watchdog.cancel() }
        let result = try body()
        print(String(format: "PASS %@ %.2fs", name, Date().timeIntervalSince(started)))
        fflush(stdout)
        return result
    }

    private static func run(executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let inactivityLimit: TimeInterval = 120
        let progressLock = NSLock()
        var lastOutput = ProcessInfo.processInfo.systemUptime
        var lastRun = "none"
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + 1, repeating: .seconds(1))
        watchdog.setEventHandler {
            progressLock.lock()
            let inactive = ProcessInfo.processInfo.systemUptime - lastOutput
            let test = lastRun
            progressLock.unlock()
            if inactive >= inactivityLimit {
                fputs("TIMEOUT Questmaster self-tests: no output for \(Int(inactivityLimit)) seconds (last RUN \(test))\n", stderr)
                if process.isRunning {
                    process.terminate()
                    let deadline = ProcessInfo.processInfo.systemUptime + 2
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if process.isRunning {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
                exit(1)
            }
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        // Drain before waiting: a child that fills the pipe blocks on write until someone reads.
        var data = Data()
        var pendingLine = ""
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            pendingLine += String(decoding: chunk, as: UTF8.self)
            let lines = pendingLine.split(separator: "\n", omittingEmptySubsequences: false)
            pendingLine = String(lines.last ?? "")
            progressLock.lock()
            lastOutput = ProcessInfo.processInfo.systemUptime
            for line in lines.dropLast() where line.hasPrefix("RUN ") {
                lastRun = String(line.dropFirst(4))
            }
            progressLock.unlock()
            FileHandle.standardOutput.write(chunk)
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func findPackageRoot() throws -> URL {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let nested = url.appendingPathComponent("app").appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: nested.path) {
            return nested.deletingLastPathComponent()
        }
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw TestFailure("could not find app Package.swift")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

try QuestmasterLogicTests.main()
