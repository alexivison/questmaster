import CryptoKit
import Darwin
import Foundation
import QuestmasterCore

struct AppBackend: Equatable {
    enum Source: String {
        case override
        case bundled
        case global
        case dev
        case unresolved
    }

    let stateRoot: String
    let executablePath: String
    let source: Source
    let backendID: String
    let runtimeToken: String
    let identityRootDirectory: String
    let runtimeDirectory: String
    let shimDirectory: String
    let pathPrefix: String
    let serveSocket: String
    let shimFallbackExecutable: String?
    let serveCommandTemplate: AppBackendCommand?
    let shim: AppBackendShim?

    func serveCommand(socketPath: String) -> ServeCommand? {
        guard let template = serveCommandTemplate else {
            return nil
        }
        return ServeCommand(
            executable: template.executable,
            arguments: template.argumentsPrefix + ["serve", "--socket", socketPath],
            workingDirectory: template.workingDirectory
        )
    }

    func prepareRuntime(fileManager: FileManager = .default) throws {
        try ensureRuntimeNamespace(fileManager: fileManager)
        try repairStaleIdentityShims(fileManager: fileManager)
        try ensureShim(fileManager: fileManager)
    }

    func ensureRuntimeNamespace(fileManager: FileManager = .default) throws {
        try createOwnerOnlyDirectory(URL(fileURLWithPath: runtimeDirectory, isDirectory: true), fileManager: fileManager)
        try createOwnerOnlyDirectory(URL(fileURLWithPath: shimDirectory, isDirectory: true), fileManager: fileManager)
    }

    func ensureShim(fileManager: FileManager = .default) throws {
        guard let shim else {
            return
        }
        try ensureRuntimeNamespace(fileManager: fileManager)
        let script = shim.script
        for name in ["qm", "questmaster"] {
            try writeExecutableScript(
                script,
                to: URL(fileURLWithPath: shimDirectory, isDirectory: true).appendingPathComponent(name),
                fileManager: fileManager
            )
        }
    }

    func repairStaleIdentityShims(fileManager: FileManager = .default) throws {
        guard let shimFallbackExecutable,
              !shimFallbackExecutable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let identities = try? fileManager.contentsOfDirectory(atPath: identityRootDirectory) else {
            return
        }

        for identity in identities {
            let identityDirectory = URL(fileURLWithPath: identityRootDirectory, isDirectory: true)
                .appendingPathComponent(identity, isDirectory: true)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: identityDirectory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            let binDirectory = identityDirectory.appendingPathComponent("bin", isDirectory: true)
            for name in ["qm", "questmaster"] {
                let shimURL = binDirectory.appendingPathComponent(name)
                guard let data = fileManager.contents(atPath: shimURL.path),
                      let content = String(data: data, encoding: .utf8) else {
                    continue
                }
                let decision = BackendShimRepair.repairDecision(
                    content: content,
                    fallbackExecutable: shimFallbackExecutable,
                    directoryExists: { directoryExists($0, fileManager: fileManager) }
                )
                if let replacement = decision.replacementContent {
                    try writeExecutableScript(replacement, to: shimURL, fileManager: fileManager)
                }
            }
        }
    }
}

struct AppBackendCommand: Equatable {
    let executable: String
    let argumentsPrefix: [String]
    let workingDirectory: String
}

struct ServeCommand {
    let executable: String
    let arguments: [String]
    let workingDirectory: String
}

enum AppBackendShim: Equatable {
    case direct(String)
    case goRun(go: String, repoRoot: String, fallbackExecutable: String?)

    var script: String {
        switch self {
        case .direct(let executable):
            return BackendShimRepair.directScript(executable: executable)
        case .goRun(let go, let repoRoot, let fallbackExecutable):
            return BackendShimRepair.devScript(go: go, repoRoot: repoRoot, fallbackExecutable: fallbackExecutable)
        }
    }
}

enum AppBackendEnvironment {
    private static let lock = NSLock()
    private static var active: AppBackend?

    static var current: AppBackend? {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    static func activate(_ backend: AppBackend) {
        lock.lock()
        active = backend
        lock.unlock()
    }

}

struct AppBackendResolver {
    private struct HashCacheEntry {
        let size: UInt64
        let modifiedAt: TimeInterval
        let hash: String
    }

    private static let hashCacheLock = NSLock()
    private static var hashCache: [String: HashCacheEntry] = [:]

    struct BundleInfo {
        let bundleURL: URL
        let resourceURL: URL?
        let executableURL: URL?

        static var main: BundleInfo {
            BundleInfo(
                bundleURL: Bundle.main.bundleURL,
                resourceURL: Bundle.main.resourceURL,
                executableURL: Bundle.main.executableURL
            )
        }
    }

    static func resolve(
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        launchServe: Bool,
        bundle: BundleInfo = .main,
        applicationSupportDirectory: URL? = nil,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        fileManager: FileManager = .default
    ) -> AppBackend {
        let home = nonEmpty(environment["HOME"]) ?? NSHomeDirectory()
        let stateRoot = canonicalPath(
            value(after: "--state-root", in: arguments)
                ?? environment["QUESTMASTER_STATE_ROOT"]
                ?? URL(fileURLWithPath: home).appendingPathComponent(".questmaster-state").path,
            relativeTo: workingDirectory
        )
        let backend = resolveBackendCommand(
            override: value(after: "--serve-executable", in: arguments)
                ?? value(after: "--qm-bin", in: arguments)
                ?? environment["QUESTMASTER_QM"],
            environment: environment,
            workingDirectory: workingDirectory,
            bundle: bundle,
            fileManager: fileManager
        )
        let backendID = backendID(for: backend, fileManager: fileManager)
        let runtimeToken = token(stateRoot: stateRoot, backendID: backendID)
        let identityRootDirectory = identityRootDirectory(home: home, applicationSupportDirectory: applicationSupportDirectory)
        let runtimeDirectory = runtimeDirectory(
            token: runtimeToken,
            identityRootDirectory: identityRootDirectory,
            temporaryDirectory: temporaryDirectory
        )
        let explicitServeSocket = value(after: "--serve-socket", in: arguments)
            ?? environment["QUESTMASTER_SERVE_SOCKET"]
        let useAppSocketNamespace = launchServe && explicitServeSocket == nil
        let serveSocket = useAppSocketNamespace
            ? URL(fileURLWithPath: runtimeDirectory).appendingPathComponent("serve.sock").path
            : canonicalPath(explicitServeSocket ?? defaultServeSocketPath(stateRoot: stateRoot, home: home), relativeTo: workingDirectory)
        let shimDirectory = URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .path

        return AppBackend(
            stateRoot: stateRoot,
            executablePath: backend.executablePath,
            source: backend.source,
            backendID: backendID,
            runtimeToken: runtimeToken,
            identityRootDirectory: identityRootDirectory,
            runtimeDirectory: runtimeDirectory,
            shimDirectory: shimDirectory,
            pathPrefix: shimDirectory,
            serveSocket: serveSocket,
            shimFallbackExecutable: bundledShimFallbackExecutable(bundle: bundle, fileManager: fileManager),
            serveCommandTemplate: backend.command,
            shim: backend.shim
        )
    }

    private static func resolveBackendCommand(
        override: String?,
        environment: [String: String],
        workingDirectory: String,
        bundle: BundleInfo,
        fileManager: FileManager
    ) -> ResolvedBackend {
        if let override,
           let executable = resolveServeExecutable(override, workingDirectory: workingDirectory, environment: environment, fileManager: fileManager) {
            return directBackend(executable: executable, source: .override, workingDirectory: workingDirectory)
        }

        if let executable = bundledServeExecutable(bundle: bundle, fileManager: fileManager) {
            return directBackend(executable: executable, source: .bundled, workingDirectory: workingDirectory)
        }

        let devBackend = resolveDevBackend(
            environment: environment,
            workingDirectory: workingDirectory,
            bundle: bundle,
            fileManager: fileManager
        )
        if bundle.bundleURL.pathExtension != "app", let devBackend {
            return devBackend
        }

        for candidate in ["qm", "questmaster"] {
            if let executable = resolveExecutable(candidate, environment: environment, fileManager: fileManager) {
                return directBackend(executable: executable, source: .global, workingDirectory: workingDirectory)
            }
        }

        if let devBackend {
            return devBackend
        }

        return ResolvedBackend(source: .unresolved, executablePath: "", command: nil, shim: nil)
    }

    private static func resolveDevBackend(
        environment: [String: String],
        workingDirectory: String,
        bundle: BundleInfo,
        fileManager: FileManager
    ) -> ResolvedBackend? {
        guard let goPath = resolveExecutable("go", environment: environment, fileManager: fileManager),
              let repoRoot = findQuestmasterRepoRoot(startingAt: workingDirectory, fileManager: fileManager) else {
            return nil
        }
        return ResolvedBackend(
            source: .dev,
            executablePath: goPath,
            command: AppBackendCommand(executable: goPath, argumentsPrefix: ["run", "."], workingDirectory: repoRoot),
            shim: .goRun(
                go: goPath,
                repoRoot: repoRoot,
                fallbackExecutable: bundledShimFallbackExecutable(bundle: bundle, fileManager: fileManager)
            )
        )
    }

    private static func directBackend(executable: String, source: AppBackend.Source, workingDirectory: String) -> ResolvedBackend {
        ResolvedBackend(
            source: source,
            executablePath: executable,
            command: AppBackendCommand(executable: executable, argumentsPrefix: [], workingDirectory: workingDirectory),
            shim: .direct(executable)
        )
    }

    private static func resolveServeExecutable(
        _ value: String,
        workingDirectory: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> String? {
        if value.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: value) ? canonicalPath(value, relativeTo: workingDirectory) : nil
        }
        if value.contains("/") {
            let path = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
                .standardizedFileURL
                .path
            return fileManager.isExecutableFile(atPath: path) ? path : nil
        }
        return resolveExecutable(value, environment: environment, fileManager: fileManager)
    }

    private static func bundledServeExecutable(bundle: BundleInfo, fileManager: FileManager) -> String? {
        guard bundle.bundleURL.pathExtension == "app" else {
            return nil
        }
        return bundledShimFallbackExecutable(bundle: bundle, fileManager: fileManager)
    }

    private static func bundledShimFallbackExecutable(bundle: BundleInfo, fileManager: FileManager) -> String? {
        let candidates = [
            bundle.resourceURL?.appendingPathComponent("qm").path,
            bundle.executableURL?
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/qm")
                .path,
        ]
        return candidates.compactMap { $0 }.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func resolveExecutable(_ name: String, environment: [String: String], fileManager: FileManager) -> String? {
        if name.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: name) ? name : nil
        }
        for directory in (environment["PATH"] ?? normalizedExecutablePath(nil, home: environment["HOME"])).split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func findQuestmasterRepoRoot(startingAt path: String, fileManager: FileManager) -> String? {
        var url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: url.appendingPathComponent("main.go").path),
               modulePath(in: url.appendingPathComponent("go.mod"), fileManager: fileManager) == "github.com/alexivison/questmaster" {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path {
                return nil
            }
            url = parent
        }
    }

    private static func modulePath(in goMod: URL, fileManager: FileManager) -> String? {
        guard let data = fileManager.contents(atPath: goMod.path),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in contents.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "module" {
                return String(parts[1])
            }
        }
        return nil
    }

    private static func backendID(for backend: ResolvedBackend, fileManager: FileManager) -> String {
        switch backend.source {
        case .dev:
            return "dev:\(backend.command?.workingDirectory ?? ""):\(devSourceToken(backend.command?.workingDirectory, fileManager: fileManager))"
        case .unresolved:
            return "unresolved"
        case .override, .bundled, .global:
            guard !backend.executablePath.isEmpty,
                  let hash = executableHash(backend.executablePath, fileManager: fileManager) else {
                return "\(backend.source.rawValue):\(backend.executablePath)"
            }
            return "sha256:\(hash)"
        }
    }

    private static func executableHash(_ path: String, fileManager: FileManager) -> String? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber,
              let modified = attrs[.modificationDate] as? Date else {
            return nil
        }
        let cacheSize = size.uint64Value
        let cacheModifiedAt = modified.timeIntervalSince1970

        hashCacheLock.lock()
        if let cached = hashCache[path],
           cached.size == cacheSize,
           cached.modifiedAt == cacheModifiedAt {
            hashCacheLock.unlock()
            return cached.hash
        }
        hashCacheLock.unlock()

        guard let data = fileManager.contents(atPath: path) else {
            return nil
        }
        let hash = sha256Hex(data)

        hashCacheLock.lock()
        hashCache[path] = HashCacheEntry(size: cacheSize, modifiedAt: cacheModifiedAt, hash: hash)
        hashCacheLock.unlock()
        return hash
    }

    private static func devSourceToken(_ directory: String?, fileManager: FileManager) -> String {
        guard let directory else {
            return "missing"
        }
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: directory, isDirectory: true),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "missing"
        }

        var parts: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "go" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                continue
            }
            let relative = url.path.hasPrefix(directory) ? String(url.path.dropFirst(directory.count)) : url.path
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            parts.append("\(relative):\(values.fileSize ?? 0):\(modified)")
        }
        return sha256Hex(Data(parts.sorted().joined(separator: "\n").utf8))
    }

    private static func token(stateRoot: String, backendID: String) -> String {
        String(sha256Hex(Data((stateRoot + "\0" + backendID).utf8)).prefix(16))
    }

    private static func runtimeDirectory(
        token: String,
        identityRootDirectory: String,
        temporaryDirectory: URL
    ) -> String {
        let preferred = URL(fileURLWithPath: identityRootDirectory, isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
            .path
        if socketPathFits(URL(fileURLWithPath: preferred).appendingPathComponent("serve.sock").path) {
            return preferred
        }

        let tempBase = temporaryDirectory
            .appendingPathComponent("qm-app-\(getuid())", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
            .path
        if socketPathFits(URL(fileURLWithPath: tempBase).appendingPathComponent("serve.sock").path) {
            return tempBase
        }

        return URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("qm-app-\(getuid())", isDirectory: true)
            .appendingPathComponent(token, isDirectory: true)
            .path
    }

    private static func identityRootDirectory(home: String, applicationSupportDirectory: URL?) -> String {
        (applicationSupportDirectory
            ?? URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Library/Application Support/Questmaster", isDirectory: true))
            .path
    }

    private static func socketPathFits(_ path: String) -> Bool {
        path.utf8.count < UnixSocketIO.pathCapacity
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct ResolvedBackend {
    let source: AppBackend.Source
    let executablePath: String
    let command: AppBackendCommand?
    let shim: AppBackendShim?
}

private func canonicalPath(_ value: String, relativeTo workingDirectory: String) -> String {
    let expanded = (value as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
        .standardizedFileURL
        .path
}

private func createOwnerOnlyDirectory(_ url: URL, fileManager: FileManager) throws {
    try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    try chmodOrThrow(url.path, 0o700)
}

private func writeExecutableScript(_ script: String, to url: URL, fileManager: FileManager) throws {
    let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
        try script.write(to: tmp, atomically: false, encoding: .utf8)
        try chmodOrThrow(tmp.path, 0o755)
        if rename(tmp.path, url.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    } catch {
        try? fileManager.removeItem(at: tmp)
        throw error
    }
}

private func directoryExists(_ path: String, fileManager: FileManager) -> Bool {
    var isDirectory = ObjCBool(false)
    return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
}

private func chmodOrThrow(_ path: String, _ mode: mode_t) throws {
    if chmod(path, mode) != 0 {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
