import Foundation
import QuestmasterCore

struct AppBackend: Equatable {
    enum Source: String { case override, bundled, global, dev, unresolved }

    let stateRoot: String
    let executablePath: String
    let source: Source
    let workingDirectory: String
    let devWorktree: String?

    func command(_ method: String) -> AppBackendCommand? {
        guard !executablePath.isEmpty else { return nil }
        if let devWorktree {
            return AppBackendCommand(
                executable: executablePath,
                arguments: ["run", ".", "daemon", method, "--build-from", devWorktree],
                workingDirectory: devWorktree
            )
        }
        return AppBackendCommand(executable: executablePath, arguments: ["daemon", method], workingDirectory: workingDirectory)
    }
}

struct AppBackendCommand: Equatable {
    let executable: String
    let arguments: [String]
    let workingDirectory: String
}

enum AppBackendEnvironment {
    private static let lock = NSLock()
    private static var active: AppBackend?
    private static var record: DaemonRecord?

    static var current: AppBackend? {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    static var daemonRecord: DaemonRecord? {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    static func activate(_ backend: AppBackend) {
        lock.lock(); active = backend; record = nil; lock.unlock()
    }

    static func use(_ newRecord: DaemonRecord) {
        lock.lock(); record = newRecord; lock.unlock()
    }
}

struct AppBackendResolver {
    struct BundleInfo {
        let bundleURL: URL
        let resourceURL: URL?
        let executableURL: URL?

        static var main: BundleInfo {
            BundleInfo(bundleURL: Bundle.main.bundleURL, resourceURL: Bundle.main.resourceURL, executableURL: Bundle.main.executableURL)
        }
    }

    static func resolve(
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        bundle: BundleInfo = .main,
        fileManager: FileManager = .default
    ) -> AppBackend {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let stateRoot = canonicalPath(
            value(after: "--state-root", in: arguments)
                ?? environment["QUESTMASTER_STATE_ROOT"]
                ?? URL(fileURLWithPath: home).appendingPathComponent(".questmaster-state").path,
            relativeTo: workingDirectory
        )
        if let override = value(after: "--qm-bin", in: arguments),
           let path = resolveExecutable(override, environment: environment, workingDirectory: workingDirectory, fileManager: fileManager) {
            return AppBackend(stateRoot: stateRoot, executablePath: path, source: .override, workingDirectory: home, devWorktree: nil)
        }
        if bundle.bundleURL.pathExtension == "app",
           let path = bundle.resourceURL?.appendingPathComponent("qm").path,
           fileManager.isExecutableFile(atPath: path) {
            return AppBackend(stateRoot: stateRoot, executablePath: path, source: .bundled, workingDirectory: home, devWorktree: nil)
        }
        if bundle.bundleURL.pathExtension != "app",
           let worktree = repoRoot(startingAt: workingDirectory, fileManager: fileManager),
           let go = resolveExecutable("go", environment: environment, workingDirectory: workingDirectory, fileManager: fileManager) {
            return AppBackend(stateRoot: stateRoot, executablePath: go, source: .dev, workingDirectory: worktree, devWorktree: worktree)
        }
        for name in ["qm", "questmaster"] {
            if let path = resolveExecutable(name, environment: environment, workingDirectory: workingDirectory, fileManager: fileManager) {
                return AppBackend(stateRoot: stateRoot, executablePath: path, source: .global, workingDirectory: home, devWorktree: nil)
            }
        }
        return AppBackend(stateRoot: stateRoot, executablePath: "", source: .unresolved, workingDirectory: home, devWorktree: nil)
    }

    private static func resolveExecutable(_ name: String, environment: [String: String], workingDirectory: String, fileManager: FileManager) -> String? {
        if name.contains("/") {
            let path = canonicalPath(name, relativeTo: workingDirectory)
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }
        for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static func repoRoot(startingAt path: String, fileManager: FileManager) -> String? {
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            let main = url.appendingPathComponent("main.go")
            let module = url.appendingPathComponent("go.mod")
            if fileManager.fileExists(atPath: main.path),
               let contents = try? String(contentsOf: module, encoding: .utf8),
               contents.contains("module github.com/alexivison/questmaster") {
                return url.resolvingSymlinksInPath().path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

func canonicalPath(_ value: String, relativeTo directory: String) -> String {
    let expanded = (value as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL.path }
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL.path
}
