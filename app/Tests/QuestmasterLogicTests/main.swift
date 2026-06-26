import Foundation

enum QuestmasterLogicTests {
    static func main() throws {
        TrackerRendererTests.run()
        RepoListClickTests.run()
        TrackerRecolorLogicTests.run()
        TrackerCommandStateTests.run()
        QuestDetailCursorTests.run()
        QuestCommentComposerTests.run()
        MutationRequestTests.run()
        NavigationLogicTests.run()
        DockWidthPreferenceTests.run()
        ServeConnectionDisplayTests.run()
        GateCompletionTests.run()
        QuestBoardLogicTests.run()
        NewSessionLogicTests.run()
        DestructiveConfirmationTests.run()
        KeymapTests.run()
        QuestSelectionTests.run()
        RuntimeDecoderTests.run()
        ContractFixtureTests.run()
        RuntimeStoreTests.run()
        NavigationStoreTests.run()
        DisplayClassificationTests.run()
        RuntimeDecodingDiagnosticsTests.run()

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
            result.output.contains("Questmaster self-tests: 38 passed"),
            "logic test pass line missing\n\(result.output)"
        )
        print(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        print("QuestmasterLogicTests: process runner passed")
    }

    private static func run(executable: String, arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
