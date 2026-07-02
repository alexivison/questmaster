#if DEBUG
import Foundation
import QuestmasterCore

enum LogicSelfTests {
    private static let cases: [(name: String, body: () throws -> Void)] = [
        ("testAppBackendResolverFeedsLaunchConfiguration", testAppBackendResolverFeedsLaunchConfiguration),
        ("testAppBackendSocketsUseShortRuntimeNamespaceAndFallback", testAppBackendSocketsUseShortRuntimeNamespaceAndFallback),
        ("testAppBackendPrepareRuntimeCreatesShimAnd0700Dirs", testAppBackendPrepareRuntimeCreatesShimAnd0700Dirs),
        ("testDevBackendBeatsGlobalPathInSourceCheckout", testDevBackendBeatsGlobalPathInSourceCheckout),
        ("testPackagedBundleBeatsDevAndGlobalBackends", testPackagedBundleBeatsDevAndGlobalBackends),
        ("testDevBackendEnvironmentUsesShimQuestmasterBin", testDevBackendEnvironmentUsesShimQuestmasterBin),
        ("testDevBackendIdentityChangesForInternalGoFile", testDevBackendIdentityChangesForInternalGoFile),
        ("testAppChildProcessEnvironmentAppliesBackendAfterNormalizedPath", testAppChildProcessEnvironmentAppliesBackendAfterNormalizedPath),
        ("testTmuxStartupScriptScopesAppBackendEnvironmentToSession", testTmuxStartupScriptScopesAppBackendEnvironmentToSession),
        ("testNavigationTogglesFocusShownRegionAndHideToTerminal", testNavigationTogglesFocusShownRegionAndHideToTerminal),
        ("testDirectionalRegionFocusMapping", testDirectionalRegionFocusMapping),
        ("testKeymapErgonomicsBindings", testKeymapErgonomicsBindings),
        ("testArtifactNavigationPolicy", testArtifactNavigationPolicy),
        ("testLocalMarkdownImageURLFiltering", testLocalMarkdownImageURLFiltering),
        ("testTrackerSkeletonMatchesServeStartupMessages", testTrackerSkeletonMatchesServeStartupMessages),
        ("testStartupTmuxSessionChoice", testStartupTmuxSessionChoice),
        ("testArtifactDockAllFiltersUseVisibleList", testArtifactDockAllFiltersUseVisibleList),
    ]

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--run-logic-tests") else {
            return false
        }

        guard !cases.isEmpty else {
            fputs("Questmaster self-tests failed: no test cases registered\n", stderr)
            exit(1)
        }

        var passed = 0
        for testCase in cases {
            do {
                try testCase.body()
                passed += 1
            } catch {
                fputs("Questmaster self-tests failed: \(testCase.name): \(error)\n", stderr)
                exit(1)
            }
        }
        print("Questmaster self-tests: \(passed) passed")
        exit(0)
    }

    private static func testAppBackendResolverFeedsLaunchConfiguration() throws {
        let fixture = try appBackendFixture()
        let config = LaunchConfiguration.load(
            arguments: [],
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            bundle: fixture.bundle,
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        )
        let backend = config.backend

        try expect(backend.stateRoot == fixture.stateRoot.path, "resolver should pin state root")
        try expect(backend.questHome == fixture.questHome.path, "resolver should pin quest home")
        try expect(backend.executablePath == fixture.qm.path, "resolver should select bundled qm")
        try expect(backend.source == .bundled, "resolver source should be bundled")
        try expect(backend.backendID.hasPrefix("sha256:"), "packaged backend identity should hash qm bytes")
        try expect(backend.runtimeToken.count == 16, "runtime token should be short")
        try expect(backend.shimDirectory == backend.pathPrefix, "path prefix should be the shim dir")
        try expect(backend.serveSocket == URL(fileURLWithPath: backend.runtimeDirectory).appendingPathComponent("serve.sock").path, "serve socket should live in runtime namespace")
        try expect(backend.focusSocket == URL(fileURLWithPath: backend.runtimeDirectory).appendingPathComponent("app-focus.sock").path, "focus socket should live in runtime namespace")
        try expect(config.serveSocket == backend.serveSocket, "LaunchConfiguration should use backend serve socket")
        try expect(config.focusSocket == backend.focusSocket, "LaunchConfiguration should use backend focus socket")
    }

    private static func testAppBackendSocketsUseShortRuntimeNamespaceAndFallback() throws {
        let fixture = try appBackendFixture()
        let longComponent = String(repeating: "x", count: 160)
        let longApplicationSupport = fixture.root.appendingPathComponent(longComponent, isDirectory: true)
        let backend = AppBackendResolver.resolve(
            arguments: [],
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            launchServe: true,
            bundle: fixture.bundle,
            applicationSupportDirectory: longApplicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        )

        try expect(!backend.runtimeDirectory.hasPrefix(longApplicationSupport.path), "long Application Support path should fall back to a short runtime base")
        try expect(backend.runtimeDirectory.contains("/qm-app-"), "fallback runtime base should be app-owned")
        try expect(backend.serveSocket.utf8.count < UnixSocketIO.pathCapacity, "serve socket should fit sun_path")
        try expect(backend.focusSocket.utf8.count < UnixSocketIO.pathCapacity, "focus socket should fit sun_path")
        try expect(
            URL(fileURLWithPath: backend.serveSocket).deletingLastPathComponent().path
                == URL(fileURLWithPath: backend.focusSocket).deletingLastPathComponent().path,
            "serve and focus sockets should share the runtime namespace"
        )
    }

    private static func testAppBackendPrepareRuntimeCreatesShimAnd0700Dirs() throws {
        let fixture = try appBackendFixture()
        let backend = LaunchConfiguration.load(
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            bundle: fixture.bundle,
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        ).backend

        try backend.prepareRuntime()

        try expect(posixMode(backend.runtimeDirectory) == 0o700, "runtime dir should be 0700")
        try expect(posixMode(backend.shimDirectory) == 0o700, "shim dir should be 0700")
        for name in ["qm", "questmaster"] {
            let shim = URL(fileURLWithPath: backend.shimDirectory).appendingPathComponent(name).path
            try expect(FileManager.default.isExecutableFile(atPath: shim), "\(name) shim should be executable")
            let body = try String(contentsOfFile: shim, encoding: .utf8)
            try expect(body.contains(fixture.qm.path), "\(name) shim should exec the resolved backend")
        }
    }

    private static func testDevBackendBeatsGlobalPathInSourceCheckout() throws {
        let fixture = try devBackendFixture()
        let globalQM = fixture.go.deletingLastPathComponent().appendingPathComponent("qm")
        try writeExecutable("#!/bin/sh\necho old qm\n", to: globalQM)

        let backend = AppBackendResolver.resolve(
            arguments: [],
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            launchServe: true,
            bundle: fixture.bundle,
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        )

        try expect(backend.source == .dev, "source checkout should prefer go run over global qm")
        try expect(backend.executablePath == fixture.go.path, "dev backend should use go executable")
        try expect(backend.serveCommandTemplate?.workingDirectory == fixture.workingDirectory.path, "dev backend should run from repo root")
    }

    private static func testPackagedBundleBeatsDevAndGlobalBackends() throws {
        let fixture = try devBackendFixture()
        let globalQM = fixture.go.deletingLastPathComponent().appendingPathComponent("qm")
        try writeExecutable("#!/bin/sh\necho old qm\n", to: globalQM)
        let app = fixture.root.appendingPathComponent("Questmaster.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let bundledQM = resources.appendingPathComponent("qm")
        let executable = macos.appendingPathComponent("Questmaster")
        try writeExecutable("#!/bin/sh\necho bundled qm\n", to: bundledQM)
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)

        let backend = AppBackendResolver.resolve(
            arguments: [],
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            launchServe: true,
            bundle: AppBackendResolver.BundleInfo(bundleURL: app, resourceURL: resources, executableURL: executable),
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        )

        try expect(backend.source == .bundled, "packaged app should prefer bundled qm")
        try expect(backend.executablePath == bundledQM.path, "packaged app should use bundled qm")
    }

    private static func testDevBackendEnvironmentUsesShimQuestmasterBin() throws {
        let fixture = try devBackendFixture()
        let backend = AppBackendResolver.resolve(
            arguments: [],
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            launchServe: true,
            bundle: fixture.bundle,
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        )
        try expect(backend.source == .dev, "fixture should resolve dev backend")

        let env = appChildProcessEnvironment(
            environment: fixture.environment,
            loginEnvironment: [:],
            backend: backend
        )
        let shimBin = URL(fileURLWithPath: backend.shimDirectory).appendingPathComponent("qm").path
        try expect(env["QUESTMASTER_BIN"] == shimBin, "dev QUESTMASTER_BIN should point at the qm-callable shim")
        try expect(env["QUESTMASTER_BIN"] != fixture.go.path, "dev QUESTMASTER_BIN should not point at raw go")
    }

    private static func testDevBackendIdentityChangesForInternalGoFile() throws {
        let fixture = try devBackendFixture()
        let first = AppBackendResolver.resolve(
            arguments: [],
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            launchServe: true,
            bundle: fixture.bundle,
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: fixture.internalGo.path
        )
        let second = AppBackendResolver.resolve(
            arguments: [],
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            launchServe: true,
            bundle: fixture.bundle,
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        )

        try expect(first.backendID != second.backendID, "internal Go file mtime should change dev backend identity")
        try expect(first.runtimeToken != second.runtimeToken, "internal Go file mtime should change dev runtime token")
    }

    private static func testAppChildProcessEnvironmentAppliesBackendAfterNormalizedPath() throws {
        let fixture = try appBackendFixture()
        let backend = LaunchConfiguration.load(
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            bundle: fixture.bundle,
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        ).backend
        let home = fixture.root.appendingPathComponent("home", isDirectory: true).path
        let env = appChildProcessEnvironment(
            additional: [
                "TMUX": "/tmp/bad",
                "TMUX_PANE": "%1",
                "TMUX_TMPDIR": "/tmp/tmux",
            ],
            environment: [
                "HOME": home,
                "PATH": "/usr/bin",
                "QUESTMASTER_QM": "/tmp/stale-qm",
            ],
            loginEnvironment: [
                "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin",
            ],
            backend: backend
        )

        try expect(env["PATH"]?.split(separator: ":").first.map(String.init) == backend.pathPrefix, "backend path prefix should survive normalization first")
        try expect(env["QUESTMASTER_BIN"] == backend.executablePath, "child env should expose backend executable")
        try expect(env["QUESTMASTER_STATE_ROOT"] == backend.stateRoot, "child env should expose state root")
        try expect(env["QUESTMASTER_HOME"] == backend.questHome, "child env should expose quest home")
        try expect(env["QUESTMASTER_PATH_PREFIX"] == backend.pathPrefix, "child env should expose path prefix")
        try expect(env["QUESTMASTER_QM"] == nil, "child env should not preserve app override input")
        try expect(env["TMUX"] == nil && env["TMUX_PANE"] == nil && env["TMUX_TMPDIR"] == nil, "child env should strip tmux variables")
    }

    private static func testTmuxStartupScriptScopesAppBackendEnvironmentToSession() throws {
        let fixture = try appBackendFixture()
        let backend = LaunchConfiguration.load(
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            bundle: fixture.bundle,
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        ).backend
        let env = [
            "HOME": fixture.root.appendingPathComponent("home", isDirectory: true).path,
            "SHELL": "/tmp/custom shell/zsh",
            "PATH": "\(backend.pathPrefix):/usr/bin",
            "QUESTMASTER_APP": "1",
            "QUESTMASTER_FOCUS_SOCKET": backend.focusSocket,
            "QUESTMASTER_STATE_ROOT": backend.stateRoot,
            "QUESTMASTER_HOME": backend.questHome,
            "QUESTMASTER_BIN": backend.executablePath,
            "QUESTMASTER_PATH_PREFIX": backend.pathPrefix,
        ]
        let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", session: "qm-test", environment: env)
        let createIndex = try substringIndex(in: script, "\"$tmux\" new-session -d -s \"$session\" sleep 2147483647")

        for key in ["PATH", "QUESTMASTER_APP", "QUESTMASTER_FOCUS_SOCKET", "QUESTMASTER_STATE_ROOT", "QUESTMASTER_HOME", "QUESTMASTER_BIN", "QUESTMASTER_PATH_PREFIX"] {
            try expect(!script.contains("set-environment -g '\(key)'"), "startup script should not globally sync \(key)")
            try expect(script.contains("set-environment -t \"$session\" '\(key)'"), "startup script should session-sync \(key)")
            let syncIndex = try substringIndex(in: script, "set-environment -t \"$session\" '\(key)'")
            try expect(createIndex < syncIndex, "startup script should create session before syncing \(key)")
        }
        for key in ["PATH", "QUESTMASTER_APP", "QUESTMASTER_FOCUS_SOCKET", "QUESTMASTER_STATE_ROOT", "QUESTMASTER_HOME", "QUESTMASTER_BIN", "QUESTMASTER_PATH_PREFIX", "QUESTMASTER_SERVE_SOCKET"] {
            try expect(script.contains("set-environment -g -r '\(key)'"), "startup script should clear stale global \(key)")
        }
        let respawnIndex = try substringIndex(in: script, "\"$tmux\" respawn-pane -k -t \"$session\":0.0")
        try expect(createIndex < respawnIndex, "startup script should respawn created panes after env sync")
        let respawnLines = script.split(separator: "\n").map(String.init)
        let respawnLine = respawnLines[try lineIndex(in: respawnLines, containing: "respawn-pane -k -t \"$session\":0.0")]
        try expect(
            !respawnLine.contains("respawn-pane -k -t \"$session\":0.0 || true"),
            "startup script should not respawn the placeholder without an explicit shell command"
        )
        try expect(respawnLine.contains("/tmp/custom shell/zsh"), "startup script should respawn using the configured shell")
        try expect(respawnLine.contains("-l"), "startup script should start a login shell")

        var fallbackEnv = env
        fallbackEnv.removeValue(forKey: "SHELL")
        let fallbackScript = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", session: "qm-test", environment: fallbackEnv)
        let fallbackLines = fallbackScript.split(separator: "\n").map(String.init)
        let fallbackRespawnLine = fallbackLines[try lineIndex(in: fallbackLines, containing: "respawn-pane -k -t \"$session\":0.0")]
        try expect(fallbackRespawnLine.contains("/bin/zsh"), "startup script should fall back to /bin/zsh")
        try expect(fallbackRespawnLine.contains("-l"), "fallback shell should be a login shell")
        try expect(script.contains("set-environment -g 'HOME'"), "startup script may still global-sync safe shell keys")
    }

    private static func testNavigationTogglesFocusShownRegionAndHideToTerminal() throws {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        try expect(state.toggleTracker() == .focused(.tracker), "showing tracker should focus tracker")
        try expect(state.trackerVisible, "tracker should show")
        try expect(state.focusedRegion == .tracker, "showing tracker should focus tracker")

        state = AppNavigationState(focusedRegion: .dock, trackerVisible: false, dockVisible: true)
        try expect(state.toggleTracker() == .focused(.tracker), "showing tracker should focus tracker from dock")
        try expect(state.trackerVisible, "tracker should show while dock is focused")
        try expect(state.focusedRegion == .tracker, "showing tracker should take focus from dock")

        state = AppNavigationState(focusedRegion: .tracker)
        try expect(state.toggleTracker() == .focused(.terminal), "hiding focused tracker should focus terminal")
        try expect(!state.trackerVisible, "tracker should hide")
        try expect(state.focusedRegion == .terminal, "hidden tracker should not keep focus")

        state = AppNavigationState(focusedRegion: .tracker, dockVisible: true)
        try expect(state.toggleDock() == .focused(.terminal), "hiding non-focused dock should focus terminal")
        try expect(!state.dockVisible, "dock should hide")
        try expect(state.focusedRegion == .terminal, "hiding non-focused dock should focus terminal")
    }

    private static func testDirectionalRegionFocusMapping() throws {
        try expect(AppNavigationState.directionalRegionTarget(from: .terminal, direction: .left) == .tracker, "terminal left should target tracker")
        try expect(AppNavigationState.directionalRegionTarget(from: .terminal, direction: .right) == .dock, "terminal right should target dock")
        try expect(AppNavigationState.directionalRegionTarget(from: .tracker, direction: .right) == .terminal, "tracker right should target terminal")
        try expect(AppNavigationState.directionalRegionTarget(from: .tracker, direction: .left) == .tracker, "tracker left should stay")
        try expect(AppNavigationState.directionalRegionTarget(from: .dock, direction: .left) == .terminal, "dock left should target terminal")
        try expect(AppNavigationState.directionalRegionTarget(from: .dock, direction: .right) == .dock, "dock right should stay")

        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        try expect(state.directionalRegionFocus(.left) == .unchanged, "terminal left should no-op when tracker is hidden")
        try expect(state.directionalRegionFocus(.right) == .unchanged, "terminal right should no-op when dock is hidden")

        state = AppNavigationState(trackerVisible: false, dockVisible: true)
        try expect(state.directionalRegionFocus(.right) == .focused(.dock), "terminal right should focus visible dock")

        state = AppNavigationState(trackerVisible: true, dockVisible: false)
        try expect(state.directionalRegionFocus(.left) == .focused(.tracker), "terminal left should focus visible tracker")
    }

    private static func testKeymapErgonomicsBindings() throws {
        try expect(Keymap.List.moveUpCharacters.keys == ["k"], "list k should move up")
        try expect(Keymap.List.moveUpKeyCodes.keyCodes.isEmpty, "list should not bind up arrow")
        try expect(Keymap.List.moveDownKeyCodes.keyCodes.isEmpty, "list should not bind down arrow")
        try expect(Keymap.List.open.keyCodes == [36, 76], "list Enter should open selection")
        try expect(!Keymap.List.open.matches(124), "list right arrow should not open selection")
        try expect(Keymap.List.delete.keys == ["d"], "list delete should be d")
        try expect(!Keymap.List.delete.matches("x"), "x should not delete list items")
        try expect(Keymap.Viewer.backKeyCodes.keyCodes == [123], "viewer back should include left arrow")
        try expect(Keymap.Viewer.back.keys.contains("h"), "viewer h should go back")
    }

    private static func testArtifactNavigationPolicy() throws {
        let httpURL = URL(string: "https://example.com")!
        try expect(
            ArtifactNavigationPolicy.decide(url: URL(string: "file:///tmp/report.html"), userInitiated: false) == .allowFile,
            "local artifact navigation should be allowed"
        )
        try expect(
            ArtifactNavigationPolicy.decide(url: httpURL, userInitiated: false) == .block,
            "non-user remote resource loads should be blocked"
        )
        try expect(
            ArtifactNavigationPolicy.decide(url: httpURL, userInitiated: true) == .openExternal(httpURL),
            "user remote clicks should open externally"
        )
        try expect(
            ArtifactNavigationPolicy.decide(url: URL(string: "javascript:alert(1)"), userInitiated: true) == .block,
            "javascript URLs should be blocked"
        )
    }

    private static func testLocalMarkdownImageURLFiltering() throws {
        let baseURL = URL(fileURLWithPath: "/tmp/artifacts", isDirectory: true)
        try expect(
            LocalMarkdownImages.fileURL(URL(string: "screenshot.png", relativeTo: baseURL))?.path == "/tmp/artifacts/screenshot.png",
            "relative image URLs should resolve against the artifact directory"
        )
        try expect(
            LocalMarkdownImages.fileURL(URL(string: "https://example.com/screenshot.png")) == nil,
            "remote markdown images should not load through the local provider"
        )
    }

    private static func testTrackerSkeletonMatchesServeStartupMessages() throws {
        try expect(trackerShowsSkeleton(for: "connecting to serve..."), "current startup text should show skeleton")
        try expect(!trackerShowsSkeleton(for: "serve not connected - retrying"), "retry text should stay visible")
    }

    private static func testArtifactDockAllFiltersUseVisibleList() throws {
        let plan = ArtifactReference(
            kind: "html",
            path: "/tmp/plan.html",
            label: "Plan",
            sessionID: "qm-a",
            projectID: "repo-a",
            addedAt: ""
        )
        let report = ArtifactReference(
            kind: "markdown",
            path: "/tmp/report.md",
            label: "Report",
            sessionID: "qm-b",
            projectID: "repo-b",
            addedAt: ""
        )
        let screenshot = ArtifactReference(
            kind: "image",
            path: "/tmp/screenshot.png",
            label: "Screenshot",
            sessionID: "qm-b",
            projectID: "repo-b",
            addedAt: ""
        )
        let misc = ArtifactReference(
            kind: "html",
            path: "/tmp/misc.html",
            label: "Misc",
            projectID: "_misc",
            addedAt: ""
        )
        let weekly = ArtifactReference(
            kind: "html",
            path: "/tmp/weekly.html",
            label: "Weekly",
            projectID: "_weekly",
            addedAt: ""
        )
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(
            repos: [
                TrackerRepo(
                    id: "repo-a",
                    name: "Alpha Repo",
                    sessions: [
                        TrackerSession(
                            id: "qm-a",
                            title: "Alpha",
                            repoIdentity: "repo-a",
                            repoName: "Alpha Repo",
                            workerCount: 0,
                            isCurrent: true
                        ),
                    ]
                ),
                TrackerRepo(
                    id: "repo-b",
                    name: "Beta Repo",
                    sessions: [
                        TrackerSession(
                            id: "qm-b",
                            title: "Beta",
                            repoIdentity: "repo-b",
                            repoName: "Beta Repo",
                            workerCount: 0,
                            isCurrent: false
                        ),
                    ]
                ),
            ],
            artifacts: [plan, report, screenshot, misc, weekly]
        )

        let model = DockPaneModel()
        _ = model.apply(
            SessionViewState(dockContent: .artifactList, artifactScope: .all),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(
            model.artifactModel.projectFilterOptions.contains(ArtifactFilterOption(id: "repo-b", title: "Beta Repo")),
            "All scope should expose project filter options from tracker repo names"
        )
        try expect(
            model.artifactModel.projectFilterOptions.contains(ArtifactFilterOption(id: "_misc", title: "misc")),
            "pseudo project names should not keep leading separator spaces"
        )
        try expect(
            model.artifactModel.projectFilterOptions.contains(ArtifactFilterOption(id: "_weekly", title: "weekly")),
            "pseudo project names should not keep leading separator spaces"
        )
        try expect(
            model.artifactModel.typeFilterOptions.contains(ArtifactFilterOption(id: "markdown", title: "Markdown")),
            "All scope should expose present artifact types"
        )
        try expect(
            model.artifactModel.typeFilterOptions.contains(ArtifactFilterOption(id: "image", title: "Image")),
            "All scope should expose image artifact types"
        )

        model.setArtifactTypeFilter("markdown", isSelected: true)
        model.setArtifactTypeFilter("image", isSelected: true)
        try expect(model.artifactModel.artifacts == [report, screenshot], "type filter should allow multiple selected values")
        try expect(model.artifactModel.selectedArtifactID == report.id, "project filter should recover selection")

        model.setArtifactTypeFilter("markdown", isSelected: false)
        model.setArtifactTypeFilter("image", isSelected: false)
        model.setArtifactProjectFilter("repo-b", isSelected: true)
        model.setArtifactProjectFilter("_misc", isSelected: true)
        try expect(model.artifactModel.artifacts == [report, screenshot, misc], "project filter should allow multiple selected values")

        model.setArtifactFilterQuery("plan")
        try expect(model.artifactModel.artifacts.isEmpty, "query/project/type filters should combine")

        _ = model.apply(
            SessionViewState(dockContent: .artifactList, artifactScope: .session),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.artifactModel.artifactFilterQuery.isEmpty, "leaving All should clear query filter")
        try expect(model.artifactModel.artifactProjectFilterIDs.isEmpty, "leaving All should clear project filter")
        try expect(model.artifactModel.artifactTypeFilterIDs.isEmpty, "leaving All should clear type filter")
        try expect(model.artifactModel.artifacts == [plan], "session scope should show session artifacts after filters clear")
    }

    private static func lineIndex(in lines: [String], containing text: String) throws -> Int {
        guard let index = lines.firstIndex(where: { $0.contains(text) }) else {
            throw TestFailure("missing line containing \(text)")
        }
        return index
    }

    private static func substringIndex(in value: String, _ needle: String) throws -> String.Index {
        guard let range = value.range(of: needle) else {
            throw TestFailure("missing substring \(needle)")
        }
        return range.lowerBound
    }

    private struct AppBackendFixture {
        let root: URL
        let workingDirectory: URL
        let stateRoot: URL
        let questHome: URL
        let qm: URL
        let bundle: AppBackendResolver.BundleInfo
        let environment: [String: String]
        let applicationSupport: URL
        let temporaryDirectory: URL
    }

    private struct DevBackendFixture {
        let root: URL
        let workingDirectory: URL
        let stateRoot: URL
        let questHome: URL
        let go: URL
        let internalGo: URL
        let bundle: AppBackendResolver.BundleInfo
        let environment: [String: String]
        let applicationSupport: URL
        let temporaryDirectory: URL
    }

    private static func appBackendFixture() throws -> AppBackendFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("questmaster-backend-test-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("work", isDirectory: true)
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let questHome = root.appendingPathComponent("home", isDirectory: true)
        let app = root.appendingPathComponent("Questmaster.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let qm = resources.appendingPathComponent("qm")
        for directory in [workingDirectory, stateRoot, questHome, resources, macos] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeExecutable("#!/bin/sh\necho qm\n", to: qm)
        let executable = macos.appendingPathComponent("Questmaster")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)

        return AppBackendFixture(
            root: root,
            workingDirectory: workingDirectory,
            stateRoot: stateRoot,
            questHome: questHome,
            qm: qm,
            bundle: AppBackendResolver.BundleInfo(bundleURL: app, resourceURL: resources, executableURL: executable),
            environment: [
                "HOME": root.appendingPathComponent("user-home", isDirectory: true).path,
                "PATH": "/usr/bin:/bin",
                "QUESTMASTER_STATE_ROOT": stateRoot.path,
                "QUESTMASTER_HOME": questHome.path,
            ],
            applicationSupport: root.appendingPathComponent("Application Support/Questmaster", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)
        )
    }

    private static func devBackendFixture() throws -> DevBackendFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("questmaster-dev-backend-test-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("repo", isDirectory: true)
        let internalDirectory = workingDirectory.appendingPathComponent("internal/session", isDirectory: true)
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let questHome = root.appendingPathComponent("home", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let go = binDirectory.appendingPathComponent("go")
        let internalGo = internalDirectory.appendingPathComponent("launch.go")
        for directory in [workingDirectory, internalDirectory, stateRoot, questHome, binDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "module github.com/alexivison/questmaster\n".write(
            to: workingDirectory.appendingPathComponent("go.mod"),
            atomically: true,
            encoding: .utf8
        )
        try "package main\nfunc main() {}\n".write(
            to: workingDirectory.appendingPathComponent("main.go"),
            atomically: true,
            encoding: .utf8
        )
        try "package session\n".write(to: internalGo, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: internalGo.path)
        try writeExecutable("#!/bin/sh\necho go\n", to: go)
        let executable = root.appendingPathComponent("Questmaster")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)

        return DevBackendFixture(
            root: root,
            workingDirectory: workingDirectory,
            stateRoot: stateRoot,
            questHome: questHome,
            go: go,
            internalGo: internalGo,
            bundle: AppBackendResolver.BundleInfo(bundleURL: executable, resourceURL: nil, executableURL: executable),
            environment: [
                "HOME": root.appendingPathComponent("user-home", isDirectory: true).path,
                "PATH": binDirectory.path,
                "QUESTMASTER_STATE_ROOT": stateRoot.path,
                "QUESTMASTER_HOME": questHome.path,
            ],
            applicationSupport: root.appendingPathComponent("Application Support/Questmaster", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true)
        )
    }

    private static func writeExecutable(_ body: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func posixMode(_ path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let mode = attrs[.posixPermissions] as? NSNumber else {
            throw TestFailure("missing posix mode for \(path)")
        }
        return mode.intValue & 0o777
    }

    private static func testStartupTmuxSessionChoice() throws {
        let sessions = [(created: 100, name: "qm-100"), (created: 300, name: "qm-300"), (created: 200, name: "qm-200")]
        try expect(
            LaunchConfiguration.startupTmuxSession(preferred: "qm-100", sessions: sessions) == "qm-100",
            "a remembered session that is still alive should win"
        )
        try expect(
            LaunchConfiguration.startupTmuxSession(preferred: "qm-999", sessions: sessions) == "qm-300",
            "a dead remembered session should fall back to newest-created"
        )
        try expect(
            LaunchConfiguration.startupTmuxSession(preferred: nil, sessions: sessions) == "qm-300",
            "no remembered session should pick newest-created"
        )
        try expect(
            LaunchConfiguration.startupTmuxSession(preferred: "qm-100", sessions: []) == nil,
            "no live sessions should return nil"
        )
    }

    private static func trackerShowsSkeleton(for observedLabel: String) -> Bool {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.apply(.serveUnavailable(observedLabel))
        return isServeStartingMessage(snapshot.serviceStateMessage)
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
#endif
