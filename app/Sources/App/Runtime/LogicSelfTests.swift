#if DEBUG
import AppKit
import Combine
import Foundation
import QuestmasterCore
import SwiftUI

@MainActor
enum LogicSelfTests {
    private static let cases: [(name: String, body: @MainActor () throws -> Void)] = [
        ("testAppBackendResolverFeedsLaunchConfiguration", testAppBackendResolverFeedsLaunchConfiguration),
        ("testAppBackendSocketsUseShortRuntimeNamespaceAndFallback", testAppBackendSocketsUseShortRuntimeNamespaceAndFallback),
        ("testAppBackendPrepareRuntimeCreatesShimAnd0700Dirs", testAppBackendPrepareRuntimeCreatesShimAnd0700Dirs),
        ("testAppBackendPrepareRuntimeRepairsStaleDevShims", testAppBackendPrepareRuntimeRepairsStaleDevShims),
        ("testDevBackendBeatsGlobalPathInSourceCheckout", testDevBackendBeatsGlobalPathInSourceCheckout),
        ("testDevBackendShimFallsBackToBundledQM", testDevBackendShimFallsBackToBundledQM),
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
        ("testRevertedShellRowsUseFreshShellAccent", testRevertedShellRowsUseFreshShellAccent),
        ("testWorkerSummaryCapsPillsAtWhatFitsWithHiddenWorkerCount", testWorkerSummaryCapsPillsAtWhatFitsWithHiddenWorkerCount),
        ("testStartupTmuxSessionChoice", testStartupTmuxSessionChoice),
        ("testDockContentRoutingAllowsGlobalQuestsOnly", testDockContentRoutingAllowsGlobalQuestsOnly),
        ("testArtifactDockCommandSwitchesFromQuests", testArtifactDockCommandSwitchesFromQuests),
        ("testDockCoordinatorKeepsNoSessionQuestState", testDockCoordinatorKeepsNoSessionQuestState),
        ("testDockCoordinatorShowsWorkerChatPerSession", testDockCoordinatorShowsWorkerChatPerSession),
        ("testDockPanePublishesModeChanges", testDockPanePublishesModeChanges),
        ("testDockSelectionPublishesImmediately", testDockSelectionPublishesImmediately),
        ("testGChordShortcutDecidesFromCharacterIgnoringCapsLock", testGChordShortcutDecidesFromCharacterIgnoringCapsLock),
        ("testQuestListGChordJumpsToEdgesAndForcesRescroll", testQuestListGChordJumpsToEdgesAndForcesRescroll),
        ("testArtifactListGChordJumpsToEdgesAndForcesRescroll", testArtifactListGChordJumpsToEdgesAndForcesRescroll),
        ("testListGChordPendingGResetsOnGAndOnInterveningKey", testListGChordPendingGResetsOnGAndOnInterveningKey),
        ("testQuestDockCopiesSelectedQuestContentsWithY", testQuestDockCopiesSelectedQuestContentsWithY),
        ("testArtifactDockCopiesSelectedArtifactPathWithY", testArtifactDockCopiesSelectedArtifactPathWithY),
        ("testArtifactDockCopiesMultipleSelectedArtifactPathsWithY", testArtifactDockCopiesMultipleSelectedArtifactPathsWithY),
        ("testArtifactDockDeletesSelectedArtifactsWithD", testArtifactDockDeletesSelectedArtifactsWithD),
        ("testArtifactViewerCopiesAndRefreshesWithKeys", testArtifactViewerCopiesAndRefreshesWithKeys),
        ("testArtifactViewerBackKeysReturnToList", testArtifactViewerBackKeysReturnToList),
        ("testNewQuestFooterTextMatchesMode", testNewQuestFooterTextMatchesMode),
        ("testSessionCoordinatorRunsSuccessCallbackOnlyAfterAck", testSessionCoordinatorRunsSuccessCallbackOnlyAfterAck),
        ("testArtifactDockAllFiltersUseVisibleList", testArtifactDockAllFiltersUseVisibleList),
        ("testDeferredDeleteConfirmationRetainsExecutor", testDeferredDeleteConfirmationRetainsExecutor),
        ("testNewSessionArrowKeysNavigatePathSuggestions", testNewSessionArrowKeysNavigatePathSuggestions),
        ("testNewSessionResolvesModelsPerAgent", testNewSessionResolvesModelsPerAgent),
        ("testNewSessionKeepsDefaultModelWhenResolveFails", testNewSessionKeepsDefaultModelWhenResolveFails),
        ("testNewSessionRefreshModelsKeyForcesARefetch", testNewSessionRefreshModelsKeyForcesARefetch),
        ("testNewSessionRefreshModelsButtonTracksInFlightState", testNewSessionRefreshModelsButtonTracksInFlightState),
        ("testNewSessionDiscardsStaleModelResponseArrivingAfterANewerOne", testNewSessionDiscardsStaleModelResponseArrivingAfterANewerOne),
        ("testNewSessionResolvesReasoningEffortsPerAgentAndModel", testNewSessionResolvesReasoningEffortsPerAgentAndModel),
        ("testNewSessionKeepsDefaultReasoningEffortWhenResolveFails", testNewSessionKeepsDefaultReasoningEffortWhenResolveFails),
        ("testNewSessionEffortKeyCyclesWhileModelFocused", testNewSessionEffortKeyCyclesWhileModelFocused),
        ("testConnectWithRetryRetriesUntilConnectSucceeds", testConnectWithRetryRetriesUntilConnectSucceeds),
        ("testConnectWithRetryGivesUpAfterExhaustingTheSchedule", testConnectWithRetryGivesUpAfterExhaustingTheSchedule),
        ("testSettingsCyclingAFieldSendsItsRoleDefaultImmediately", testSettingsCyclingAFieldSendsItsRoleDefaultImmediately),
        ("testSettingsCloseDoesNotWaitForInFlightSaves", testSettingsCloseDoesNotWaitForInFlightSaves),
        ("testSettingsFailedSaveSurfacesErrorMessage", testSettingsFailedSaveSurfacesErrorMessage),
        ("testSettingsResendsAnEditMadeWhileAPreviousSaveIsInFlight", testSettingsResendsAnEditMadeWhileAPreviousSaveIsInFlight),
        ("testActionBarFooterHeightIsIntegral", testActionBarFooterHeightIsIntegral),
        ("testActionBarSlotsCentreInsideFooter", testActionBarSlotsCentreInsideFooter),
        ("testScrollerHidingSurvivesCompetingResetQueuedRightBehindIt", testScrollerHidingSurvivesCompetingResetQueuedRightBehindIt),
        ("testWorkerChatFollowerGlidesArrivalsAndKeepsFollowingMidGlide", testWorkerChatFollowerGlidesArrivalsAndKeepsFollowingMidGlide),
        ("testWorkerChatFollowerDoesNotGlideOnTrimOrResize", testWorkerChatFollowerDoesNotGlideOnTrimOrResize),
        ("testWorkerChatEqualHeightTrimDoesNotSkipTheNextArrivalGlide", testWorkerChatEqualHeightTrimDoesNotSkipTheNextArrivalGlide),
        ("testWorkerChatRepeatedRenderBeforeLayoutKeepsTrimSuppressed", testWorkerChatRepeatedRenderBeforeLayoutKeepsTrimSuppressed),
        ("testWorkerChatArrivalFadesItsRowsIn", testWorkerChatArrivalFadesItsRowsIn),
        ("testWorkerChatArrivalDuringAFadeKeepsTheEarlierBand", testWorkerChatArrivalDuringAFadeKeepsTheEarlierBand),
        ("testWorkerChatBurstFadesEveryNewRowInOneBand", testWorkerChatBurstFadesEveryNewRowInOneBand),
        ("testWorkerChatFadesEndIntoTheBaseAndLeaveNoMask", testWorkerChatFadesEndIntoTheBaseAndLeaveNoMask),
        ("testWorkerChatFadeNeedsFollowingAndAnAppend", testWorkerChatFadeNeedsFollowingAndAnAppend),
        ("testWorkerChatTrimAndResizeEndARunningFade", testWorkerChatTrimAndResizeEndARunningFade),
        ("testWorkerChatLiveScrollCancelsGlide", testWorkerChatLiveScrollCancelsGlide),
        ("testWorkerChatTrimWithWrappedRowsSkipsGlide", testWorkerChatTrimWithWrappedRowsSkipsGlide),
        ("testWorkerChatHostedArrivalGlidesAndFades", testWorkerChatHostedArrivalGlidesAndFades),
        ("testWorkerChatShortFeedArrivalFadesAndLifts", testWorkerChatShortFeedArrivalFadesAndLifts),
        ("testWorkerChatRowsGrowingBeforeTheDocumentKeepTheMaskOverTheirFade", testWorkerChatRowsGrowingBeforeTheDocumentKeepTheMaskOverTheirFade),
        ("testWorkerChatNonAppendUpdateEndsAFadeWithoutAGeometryChange", testWorkerChatNonAppendUpdateEndsAFadeWithoutAGeometryChange),
        ("testWorkerChatCrossingTheViewportGlidesRowsFromTheirOldPlace", testWorkerChatCrossingTheViewportGlidesRowsFromTheirOldPlace),
        ("testWorkerChatNameStartsPastLogoInAnyChatFont", testWorkerChatNameStartsPastLogoInAnyChatFont),
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
        try expect(backend.executablePath == fixture.qm.path, "resolver should select bundled qm")
        try expect(backend.source == .bundled, "resolver source should be bundled")
        try expect(backend.backendID.hasPrefix("sha256:"), "packaged backend identity should hash qm bytes")
        try expect(backend.runtimeToken.count == 16, "runtime token should be short")
        try expect(backend.shimDirectory == backend.pathPrefix, "path prefix should be the shim dir")
        try expect(backend.serveSocket == URL(fileURLWithPath: backend.runtimeDirectory).appendingPathComponent("serve.sock").path, "serve socket should live in runtime namespace")
        try expect(config.serveSocket == backend.serveSocket, "LaunchConfiguration should use backend serve socket")
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
    }

    private static func testRevertedShellRowsUseFreshShellAccent() throws {
        let fresh = TrackerSession(
            id: "fresh-shell",
            title: "Shell",
            repoName: "",
            agent: ""
        )
        let reverted = TrackerSession(
            id: "reverted-shell",
            title: "Shell",
            repoIdentity: "/repo/.git",
            repoName: "Repo",
            repoPath: "/repo",
            repoColor: "green",
            displayColor: "magenta",
            agent: "",
            state: "done",
            lifecycle: "active"
        )
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: TrackerRepo.grouping([fresh, reverted]))

        let rows = TrackerRenderer.tracker(snapshot).flatMap { repo in
            repo.groups.flatMap { group in
                [group.root] + group.workers
            }
        }
        let freshColor = try renderedColor(rows, id: "fresh-shell")
        let revertedColor = try renderedColor(rows, id: "reverted-shell")

        try expect(freshColor.isEqual(AppPalette.muted), "fresh shell should use muted accent")
        try expect(revertedColor.isEqual(freshColor), "reverted shell should keep fresh shell accent")
    }

    private static func testWorkerSummaryCapsPillsAtWhatFitsWithHiddenWorkerCount() throws {
        func pills(_ workers: [(agent: String, state: String)]) throws -> [TrackerWorkerSummary.Pill] {
            let master = TrackerSession(id: "master", title: "Master", repoName: "Preview", role: "master")
            let sessions = [master] + workers.enumerated().map { index, worker in
                TrackerSession(
                    id: "worker-\(index)",
                    title: "Worker \(index)",
                    repoName: "Preview",
                    agent: worker.agent,
                    role: "worker",
                    state: worker.state,
                    parentID: master.id
                )
            }
            var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
            snapshot.tracker = TrackerSnapshot(repos: [TrackerRepo(id: "preview", name: "Preview", sessions: sessions)])
            guard let group = TrackerRenderer.tracker(snapshot).first?.groups.first else {
                throw TestFailure("tracker renderer should keep the master group")
            }
            return TrackerWorkerSummary.pills(for: group.workers)
        }

        // Distinct (agent, status) groups, the first with two workers and the rest with one.
        let distinctGroups: [(agent: String, state: String)] = [
            ("codex", "working"), ("codex", "idle"), ("claude", "working"), ("claude", "idle"),
            ("pi", "blocked"), ("opencode", "idle"), ("pi", "working"), ("opencode", "working"),
            ("codex", "blocked"), ("claude", "blocked"), ("pi", "idle"), ("opencode", "blocked"),
        ]
        let fit = TrackerWorkerSummary.maxPills
        try expect(fit >= 2 && fit < distinctGroups.count, "pill capacity should be a small positive number, got \(fit)")

        let fitting = try pills(Array(distinctGroups.prefix(fit)))
        try expect(fitting.count == fit, "\(fit) groups should show \(fit) pills, got \(fitting.count)")
        try expect(fitting.allSatisfy { if case .group = $0 { true } else { false } }, "groups that fit should not overflow")

        let crowded = Array(distinctGroups.prefix(fit + 3)) + [distinctGroups[0]]
        let overflowing = try pills(crowded)
        try expect(overflowing.count == fit, "more groups than fit should show \(fit) pills, got \(overflowing.count)")
        var shownWorkers = 0
        for pill in overflowing.prefix(fit - 1) {
            guard case .group(let group) = pill else {
                throw TestFailure("the first \(fit - 1) pills should be groups")
            }
            shownWorkers += group.count
        }
        guard case .overflow(let hiddenWorkers) = overflowing[fit - 1] else {
            throw TestFailure("the last pill should be the overflow pill")
        }
        try expect(hiddenWorkers == crowded.count - shownWorkers, "overflow should count hidden workers (\(crowded.count - shownWorkers)), got \(hiddenWorkers)")
        try expect(hiddenWorkers >= 4, "at least the four hidden groups should be counted, got \(hiddenWorkers)")
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

    private static func testAppBackendPrepareRuntimeRepairsStaleDevShims() throws {
        let fixture = try appBackendFixture()
        let backend = LaunchConfiguration.load(
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            bundle: fixture.bundle,
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        ).backend
        let staleBin = fixture.applicationSupport
            .appendingPathComponent("stale", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let liveRoot = fixture.root.appendingPathComponent("live-worktree", isDirectory: true)
        let liveBin = fixture.applicationSupport
            .appendingPathComponent("live", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: staleBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: liveBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        let staleShim = BackendShimRepair.devScript(go: "/usr/bin/go", repoRoot: "/tmp/deleted-worktree", fallbackExecutable: "/old/qm")
        let liveShim = BackendShimRepair.devScript(go: "/usr/bin/go", repoRoot: liveRoot.path, fallbackExecutable: "/old/qm")
        for name in ["qm", "questmaster"] {
            try writeExecutable(staleShim, to: staleBin.appendingPathComponent(name))
            try writeExecutable(liveShim, to: liveBin.appendingPathComponent(name))
        }

        try backend.prepareRuntime()

        for name in ["qm", "questmaster"] {
            let repaired = try String(contentsOf: staleBin.appendingPathComponent(name), encoding: .utf8)
            try expect(repaired == BackendShimRepair.directScript(executable: fixture.qm.path), "\(name) stale shim should be rewritten to bundled qm")
        }
        let preserved = try String(contentsOf: liveBin.appendingPathComponent("qm"), encoding: .utf8)
        try expect(preserved == liveShim, "live dev shim should stay unchanged")
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

    private static func testDevBackendShimFallsBackToBundledQM() throws {
        let fixture = try devBackendFixture()
        let resources = fixture.root.appendingPathComponent("Resources", isDirectory: true)
        let bundledQM = resources.appendingPathComponent("qm")
        try writeExecutable("#!/bin/sh\necho bundled qm\n", to: bundledQM)
        let backend = AppBackendResolver.resolve(
            arguments: [],
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            launchServe: true,
            bundle: AppBackendResolver.BundleInfo(
                bundleURL: fixture.bundle.bundleURL,
                resourceURL: resources,
                executableURL: fixture.bundle.executableURL
            ),
            applicationSupportDirectory: fixture.applicationSupport,
            temporaryDirectory: fixture.temporaryDirectory
        )
        try expect(backend.source == .dev, "fixture should still resolve dev backend")

        try backend.prepareRuntime()

        let shim = URL(fileURLWithPath: backend.shimDirectory).appendingPathComponent("qm")
        let body = try String(contentsOf: shim, encoding: .utf8)
        try expect(body.contains("cd '\(fixture.workingDirectory.path)' && exec '\(fixture.go.path)' run . \"$@\""), "dev shim should gate go run behind cd")
        try expect(body.contains("exec '\(bundledQM.path)' \"$@\""), "dev shim should fall back to bundled qm")
        try expect(!body.contains("\nexec '\(fixture.go.path)' run . \"$@\""), "dev shim should not run go from caller cwd")
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
                "QUESTMASTER_HOME": "/tmp/legacy-questmaster-home",
            ],
            loginEnvironment: [
                "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/bin",
            ],
            backend: backend
        )

        try expect(env["PATH"]?.split(separator: ":").first.map(String.init) == backend.pathPrefix, "backend path prefix should survive normalization first")
        try expect(env["QUESTMASTER_BIN"] == backend.executablePath, "child env should expose backend executable")
        try expect(env["QUESTMASTER_STATE_ROOT"] == backend.stateRoot, "child env should expose state root")
        try expect(env["QUESTMASTER_HOME"] == nil, "child env should clear legacy quest home")
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
            "QUESTMASTER_STATE_ROOT": backend.stateRoot,
            "QUESTMASTER_BIN": backend.executablePath,
            "QUESTMASTER_PATH_PREFIX": backend.pathPrefix,
        ]
        let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", session: "qm-test", environment: env)
        let createIndex = try substringIndex(in: script, "\"$tmux\" new-session -d -s \"$session\" sleep 2147483647")

        try expect(!script.contains("exec \"$tmux\" attach-session"), "startup script should not exec tmux attach")
        let attachIndex = try substringIndex(in: script, "\"$tmux\" attach-session -t \"$session\" || true")
        let markerIndex = try substringIndex(in: script, "printf '\\033]0;\(TerminalDetachSignal.markerTitle)\\007'")
        let unsetIndex = try substringIndex(in: script, "unset QUESTMASTER_SESSION TMUX TMUX_PANE || true")
        let shellExecIndex = try substringIndex(in: script, "exec '/tmp/custom shell/zsh' -l")
        try expect(attachIndex < markerIndex, "startup script should mark detach after attach returns")
        try expect(markerIndex < unsetIndex, "startup script should clear session env after marker")
        try expect(unsetIndex < shellExecIndex, "startup script should exec shell after clearing session env")

        for key in ["PATH", "QUESTMASTER_APP", "QUESTMASTER_STATE_ROOT", "QUESTMASTER_BIN", "QUESTMASTER_PATH_PREFIX"] {
            try expect(!script.contains("set-environment -g '\(key)'"), "startup script should not globally sync \(key)")
            try expect(script.contains("set-environment -t \"$session\" '\(key)'"), "startup script should session-sync \(key)")
            let syncIndex = try substringIndex(in: script, "set-environment -t \"$session\" '\(key)'")
            try expect(createIndex < syncIndex, "startup script should create session before syncing \(key)")
        }
        for key in ["PATH", "QUESTMASTER_APP", "QUESTMASTER_STATE_ROOT", "QUESTMASTER_BIN", "QUESTMASTER_PATH_PREFIX", "QUESTMASTER_SERVE_SOCKET"] {
            try expect(script.contains("set-environment -g -r '\(key)'"), "startup script should clear stale global \(key)")
        }
        try expect(script.contains("set-environment -g -r 'QUESTMASTER_HOME'"), "startup script should clear stale global quest home")
        try expect(script.contains("set-environment -t \"$session\" -r 'QUESTMASTER_HOME'"), "startup script should clear session quest home")
        let respawnIndex = try substringIndex(in: script, "\"$tmux\" respawn-pane -k -t \"$session\":0.0")
        try expect(createIndex < respawnIndex, "startup script should respawn created panes after env sync")
        let respawnLines = script.split(separator: "\n").map(String.init)
        let respawnLine = respawnLines[try lineIndex(in: respawnLines, containing: "respawn-pane -k -t \"$session\":0.0")]
        try expect(respawnLines.last == "exec '/tmp/custom shell/zsh' -l", "startup script should end by execing the login shell")
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
        try expect(Keymap.Command.deleteFocusedSession.keyEquivalent == "d", "focused session delete should use d")
        try expect(Keymap.Command.deleteFocusedSession.modifiers == [.command, .shift], "focused session delete should use command-shift-d")
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
        try expect(trackerShowsSkeleton(for: "serve not connected - retrying"), "retry text should keep showing the skeleton, it will resolve itself")
        try expect(!trackerShowsSkeleton(for: "serve stopped - restart required"), "restart-required is terminal and should show as a normal empty state")
    }

    private static func testDockPanePublishesModeChanges() throws {
        let model = DockPaneModel()
        let snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        var publishCount = 0
        let cancellable = model.objectWillChange.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let beforeQuest = publishCount
        _ = model.apply(
            SessionViewState(dockContent: .questList),
            snapshot: snapshot,
            preferredArtifactSessionID: nil
        )
        try expect(model.currentMode == .quests, "quest dock content should render quest mode")
        try expect(publishCount > beforeQuest, "quest mode change should publish for DockRootView")

        let beforeArtifacts = publishCount
        _ = model.apply(
            SessionViewState(dockContent: .artifactList),
            snapshot: snapshot,
            preferredArtifactSessionID: nil
        )
        try expect(model.currentMode == .artifacts, "artifact dock content should render artifact mode")
        try expect(publishCount > beforeArtifacts, "artifact mode change should publish for DockRootView")
    }

    private static func testDockSelectionPublishesImmediately() throws {
        let first = ArtifactReference(kind: "html", path: "/tmp/first.html", label: "First", sessionID: "qm-a", addedAt: "")
        let second = ArtifactReference(kind: "html", path: "/tmp/second.html", label: "Second", sessionID: "qm-a", addedAt: "")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(
            repos: [TrackerRepo(id: "repo-a", name: "Alpha", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", workerCount: 0, isCurrent: true, artifacts: [first, second]),
            ])],
            quests: [
                QuestItem(id: "qst-a", content: "First quest"),
                QuestItem(id: "qst-b", content: "Second quest"),
            ]
        )

        let coordinator = DockCoordinator()
        let model = DockPaneModel()
        model.onSelectedArtifactChange = { coordinator.updateSelectedArtifact($0, sessionID: "qm-a") }
        model.onSelectedQuestChange = { coordinator.updateSelectedQuest($0, sessionID: "qm-a") }

        _ = model.apply(
            SessionViewState(dockContent: .artifactList, selectedArtifactID: first.id),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.handleKeyDown(try keyEvent("j", keyCode: 38), snapshot: snapshot), "j should select the next artifact")
        try expect(coordinator.state(for: "qm-a").selectedArtifactID == second.id, "artifact selection should persist before the next render")

        _ = model.apply(
            coordinator.state(for: "qm-a"),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.artifactModel.selectedArtifactID == second.id, "render should retain the selected artifact")

        _ = model.apply(
            SessionViewState(dockContent: .questList, selectedQuestID: "qst-a"),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        model.selectQuest("qst-b")
        try expect(coordinator.state(for: "qm-a").selectedQuestID == "qst-b", "quest selection should persist before the next render")
    }

    private static func testGChordShortcutDecidesFromCharacterIgnoringCapsLock() throws {
        try expect(GChordShortcut.isPrefix(try keyEvent("g", keyCode: 5)), "plain g should arm the chord")
        try expect(!GChordShortcut.isJumpToBottom(try keyEvent("g", keyCode: 5)), "plain g should not jump to bottom")

        try expect(GChordShortcut.isJumpToBottom(try keyEvent("G", keyCode: 5, modifierFlags: [.shift])), "shift-G should jump to bottom")
        try expect(!GChordShortcut.isPrefix(try keyEvent("G", keyCode: 5, modifierFlags: [.shift])), "shift-G should not arm the chord")

        // Caps Lock alone types "G" without Shift being held; the decision must follow the
        // resulting character, not a `flags == [.shift]` match.
        try expect(GChordShortcut.isJumpToBottom(try keyEvent("G", keyCode: 5, modifierFlags: [.capsLock])), "caps-lock G should jump to bottom")
        try expect(!GChordShortcut.isPrefix(try keyEvent("G", keyCode: 5, modifierFlags: [.capsLock])), "caps-lock G should not arm the chord")

        // Caps Lock plus Shift cancel out back to lowercase "g".
        try expect(GChordShortcut.isPrefix(try keyEvent("g", keyCode: 5, modifierFlags: [.capsLock, .shift])), "caps-lock+shift g should arm the chord")
        try expect(!GChordShortcut.isJumpToBottom(try keyEvent("g", keyCode: 5, modifierFlags: [.capsLock, .shift])), "caps-lock+shift g should not jump to bottom")

        try expect(!GChordShortcut.isPrefix(try keyEvent("g", keyCode: 5, modifierFlags: [.command])), "command-g should not arm the chord")
        try expect(!GChordShortcut.isJumpToBottom(try keyEvent("G", keyCode: 5, modifierFlags: [.command, .shift])), "command-shift-G should not jump to bottom")
    }

    private static func testQuestListGChordJumpsToEdgesAndForcesRescroll() throws {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(
            repos: [],
            quests: [
                QuestItem(id: "qst-a", content: "A", updatedAt: "2026-07-03T01:00:00Z"),
                QuestItem(id: "qst-b", content: "B", updatedAt: "2026-07-03T02:00:00Z"),
                QuestItem(id: "qst-c", content: "C", updatedAt: "2026-07-03T03:00:00Z"),
            ]
        )
        // Sorted newest first within the "no project" bucket: [qst-c, qst-b, qst-a].
        let model = DockPaneModel()
        _ = model.apply(
            SessionViewState(dockContent: .questList, selectedQuestID: "qst-c"),
            snapshot: snapshot,
            preferredArtifactSessionID: nil
        )

        let shiftG = try keyEvent("G", keyCode: 5, modifierFlags: [.shift])
        try expect(model.handleKeyDown(shiftG, snapshot: snapshot), "G should be handled")
        try expect(model.questModel.selectedQuestID == "qst-a", "G should select the last quest")
        let nonceAfterFirstJump = model.questModel.scrollNonce

        try expect(model.handleKeyDown(shiftG, snapshot: snapshot), "G should still be handled when already at the last quest")
        try expect(model.questModel.scrollNonce != nonceAfterFirstJump, "repeating G at the edge should still force a rescroll")

        let g = try keyEvent("g", keyCode: 5)
        try expect(model.handleKeyDown(g, snapshot: snapshot), "first g should arm the gg chord")
        try expect(model.handleKeyDown(g, snapshot: snapshot), "second g within the window should jump to the first quest")
        try expect(model.questModel.selectedQuestID == "qst-c", "gg should select the first quest")
    }

    private static func testArtifactListGChordJumpsToEdgesAndForcesRescroll() throws {
        let first = ArtifactReference(kind: "html", path: "/tmp/first.html", label: "First", sessionID: "qm-a", addedAt: "")
        let second = ArtifactReference(kind: "html", path: "/tmp/second.html", label: "Second", sessionID: "qm-a", addedAt: "")
        let third = ArtifactReference(kind: "html", path: "/tmp/third.html", label: "Third", sessionID: "qm-a", addedAt: "")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "repo-a", name: "Alpha", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", workerCount: 0, isCurrent: true, artifacts: [first, second, third]),
            ]),
        ])

        let model = DockPaneModel()
        _ = model.apply(
            SessionViewState(dockContent: .artifactList, selectedArtifactID: first.id),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )

        let shiftG = try keyEvent("G", keyCode: 5, modifierFlags: [.shift])
        try expect(model.handleKeyDown(shiftG, snapshot: snapshot), "G should be handled")
        try expect(model.artifactModel.selectedArtifactID == third.id, "G should select the last artifact")
        let nonceAfterFirstJump = model.artifactModel.scrollNonce

        try expect(model.handleKeyDown(shiftG, snapshot: snapshot), "G should still be handled when already at the last artifact")
        try expect(model.artifactModel.scrollNonce != nonceAfterFirstJump, "repeating G at the edge should still force a rescroll")

        let g = try keyEvent("g", keyCode: 5)
        try expect(model.handleKeyDown(g, snapshot: snapshot), "first g should arm the gg chord")
        try expect(model.handleKeyDown(g, snapshot: snapshot), "second g within the window should jump to the first artifact")
        try expect(model.artifactModel.selectedArtifactID == first.id, "gg should select the first artifact")
    }

    private static func testListGChordPendingGResetsOnGAndOnInterveningKey() throws {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(
            repos: [],
            quests: [
                QuestItem(id: "qst-a", content: "A", updatedAt: "2026-07-03T01:00:00Z"),
                QuestItem(id: "qst-b", content: "B", updatedAt: "2026-07-03T02:00:00Z"),
                QuestItem(id: "qst-c", content: "C", updatedAt: "2026-07-03T03:00:00Z"),
            ]
        )
        let g = try keyEvent("g", keyCode: 5)
        let shiftG = try keyEvent("G", keyCode: 5, modifierFlags: [.shift])

        let afterG = DockPaneModel()
        _ = afterG.apply(
            SessionViewState(dockContent: .questList, selectedQuestID: "qst-b"),
            snapshot: snapshot,
            preferredArtifactSessionID: nil
        )
        try expect(afterG.handleKeyDown(g, snapshot: snapshot), "g should arm the chord")
        try expect(afterG.handleKeyDown(shiftG, snapshot: snapshot), "G should jump to the last quest, not continue the chord")
        try expect(afterG.questModel.selectedQuestID == "qst-a", "G should select the last quest")
        try expect(afterG.handleKeyDown(g, snapshot: snapshot), "g right after G should re-arm rather than resolve")
        try expect(afterG.questModel.selectedQuestID == "qst-a", "a freshly re-armed g alone should not move the selection")

        let afterOtherKey = DockPaneModel()
        _ = afterOtherKey.apply(
            SessionViewState(dockContent: .questList, selectedQuestID: "qst-b"),
            snapshot: snapshot,
            preferredArtifactSessionID: nil
        )
        try expect(afterOtherKey.handleKeyDown(g, snapshot: snapshot), "g should arm the chord")
        _ = afterOtherKey.handleKeyDown(try keyEvent("/", keyCode: 44), snapshot: snapshot)
        try expect(afterOtherKey.handleKeyDown(g, snapshot: snapshot), "g after an unrelated key should re-arm rather than resolve")
        try expect(afterOtherKey.questModel.selectedQuestID == "qst-b", "a freshly re-armed g alone should not move the selection")
    }

    private static func testQuestDockCopiesSelectedQuestContentsWithY() throws {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(
            repos: [],
            quests: [
                QuestItem(id: "qst-a", content: "Copy this quest", updatedAt: "2026-07-06T09:00:00Z"),
            ]
        )
        let model = DockPaneModel()
        var copiedCount = 0
        model.onCopyQuests = { copiedCount = $0 }
        _ = model.apply(
            SessionViewState(dockContent: .questList, selectedQuestID: "qst-a"),
            snapshot: snapshot,
            preferredArtifactSessionID: nil
        )

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: 16
        ) else {
            throw TestFailure("could not create y key event")
        }

        try expect(model.handleKeyDown(event, snapshot: snapshot), "y should copy the selected quest")
        try expect(
            pasteboard.string(forType: .string) == "Copy this quest",
            "pasteboard should contain selected quest content"
        )
        try expect(copiedCount == 1, "copy quest should report copied count")
    }

    private static func testArtifactDockCopiesSelectedArtifactPathWithY() throws {
        let artifact = ArtifactReference(
            kind: "html",
            path: "/tmp/plan.html",
            label: "Plan",
            sessionID: "qm-a",
            addedAt: ""
        )
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "repo-a", name: "Alpha Repo", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, isCurrent: true, artifacts: [artifact]),
            ]),
        ])

        let model = DockPaneModel()
        var copied = false
        model.onCopyArtifactPath = { copied = true }
        _ = model.apply(
            SessionViewState(dockContent: .artifactList, selectedArtifactID: artifact.id),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }

        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "y",
            charactersIgnoringModifiers: "y",
            isARepeat: false,
            keyCode: 16
        ) else {
            throw TestFailure("could not create y key event")
        }

        try expect(model.handleKeyDown(event, snapshot: snapshot), "y should copy the selected artifact")
        try expect(
            pasteboard.string(forType: .string) == artifact.path,
            "pasteboard should contain selected artifact path"
        )
        try expect(copied, "copy artifact should report success")
    }

    private static func testArtifactDockCopiesMultipleSelectedArtifactPathsWithY() throws {
        let artifact = ArtifactReference(
            kind: "html",
            path: "/tmp/plan.html",
            label: "Plan",
            sessionID: "qm-a",
            addedAt: ""
        )
        let secondArtifact = ArtifactReference(
            kind: "markdown",
            path: "/tmp/notes.md",
            label: "Notes",
            sessionID: "qm-a",
            addedAt: ""
        )
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "repo-a", name: "Alpha Repo", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, isCurrent: true, artifacts: [artifact, secondArtifact]),
            ]),
        ])
        let model = DockPaneModel()
        _ = model.apply(
            SessionViewState(dockContent: .artifactList, selectedArtifactID: artifact.id),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }

        try expect(model.handleKeyDown(try keyEvent(" ", keyCode: 49), snapshot: snapshot), "Space should select the current artifact")
        try expect(model.handleKeyDown(try keyEvent("j", keyCode: 38), snapshot: snapshot), "j should select the next artifact")
        try expect(model.handleKeyDown(try keyEvent(" ", keyCode: 49), snapshot: snapshot), "Space should select another artifact")
        try expect(model.handleKeyDown(try keyEvent("y", keyCode: 16), snapshot: snapshot), "y should copy the selected artifacts")
        try expect(
            pasteboard.string(forType: .string) == "\(artifact.path)\n\(secondArtifact.path)",
            "pasteboard should contain both selected artifact paths joined by newline"
        )
    }

    private static func testArtifactDockDeletesSelectedArtifactsWithD() throws {
        let artifact = ArtifactReference(
            kind: "html",
            path: "/tmp/plan.html",
            label: "Plan",
            sessionID: "qm-a",
            addedAt: ""
        )
        let secondArtifact = ArtifactReference(
            kind: "markdown",
            path: "/tmp/notes.md",
            label: "Notes",
            sessionID: "qm-a",
            addedAt: ""
        )
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "repo-a", name: "Alpha Repo", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, isCurrent: true, artifacts: [artifact, secondArtifact]),
            ]),
        ])
        let model = DockPaneModel()
        var deleted: [ArtifactReference] = []
        model.onDeleteArtifacts = { deleted = $0 }
        _ = model.apply(
            SessionViewState(dockContent: .artifactList, selectedArtifactID: artifact.id),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )

        try expect(model.handleKeyDown(try keyEvent(" ", keyCode: 49), snapshot: snapshot), "Space should select the current artifact")
        try expect(model.handleKeyDown(try keyEvent("j", keyCode: 38), snapshot: snapshot), "j should select the next artifact")
        try expect(model.handleKeyDown(try keyEvent(" ", keyCode: 49), snapshot: snapshot), "Space should select another artifact")
        try expect(model.handleKeyDown(try keyEvent("d", keyCode: 2), snapshot: snapshot), "d should delete the selected artifacts")
        try expect(deleted == [artifact, secondArtifact], "d should request deletion of selected artifacts")
        try expect(model.artifactModel.selectedArtifactIDs == Set([artifact.id, secondArtifact.id]), "deletion request should retain selection until the runtime updates")
    }

    private static func testArtifactViewerBackKeysReturnToList() throws {
        let artifact = ArtifactReference(
            kind: "html",
            path: "/tmp/plan.html",
            label: "Plan",
            sessionID: "qm-a",
            addedAt: ""
        )
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "repo-a", name: "Alpha Repo", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, isCurrent: true, artifacts: [artifact]),
            ]),
        ])

        let model = DockPaneModel()
        var backCount = 0
        model.onShowArtifactListIntent = { backCount += 1 }
        _ = model.apply(
            SessionViewState(dockContent: .artifactViewer, selectedArtifactID: artifact.id),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )

        let events: [(String, UInt16)] = [("h", 4), ("\u{1b}", 53), ("", 123)]
        for (characters, keyCode) in events {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: keyCode == 123 ? [.numericPad] : [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ) else {
                throw TestFailure("could not create artifact viewer back event")
            }
            try expect(model.handleKeyDown(event, snapshot: snapshot), "artifact viewer back key should be handled")
        }
        try expect(backCount == events.count, "artifact viewer back keys should request the artifact list")
    }

    private static func testArtifactViewerCopiesAndRefreshesWithKeys() throws {
        let artifact = ArtifactReference(
            kind: "html",
            path: "/tmp/plan.html",
            label: "Plan",
            sessionID: "qm-a",
            addedAt: ""
        )
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "repo-a", name: "Alpha Repo", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, isCurrent: true, artifacts: [artifact]),
            ]),
        ])

        let model = DockPaneModel()
        var copied = false
        model.onCopyArtifactPath = { copied = true }
        _ = model.apply(
            SessionViewState(dockContent: .artifactViewer, selectedArtifactID: artifact.id),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previous {
                pasteboard.setString(previous, forType: .string)
            }
        }

        try expect(model.handleKeyDown(try keyEvent("y", keyCode: 16), snapshot: snapshot), "viewer y should copy artifact path")
        try expect(pasteboard.string(forType: .string) == artifact.path, "viewer y should copy selected artifact path")
        try expect(copied, "viewer y should report copied artifact path")

        let beforeReload = model.artifactModel.reloadNonce
        try expect(model.handleKeyDown(try keyEvent("r", keyCode: 15), snapshot: snapshot), "viewer r should refresh")
        try expect(model.artifactModel.reloadNonce == beforeReload + 1, "viewer r should increment reload nonce")
    }

    private static func testDockContentRoutingAllowsGlobalQuestsOnly() throws {
        try expect(DockContentRouting.canShow(.questList, sessionID: nil), "quest list should open without a current session")
        try expect(DockContentRouting.canShow(.questList, sessionID: "   "), "quest list should open without a session id")
        try expect(!DockContentRouting.canShow(.artifactList, sessionID: nil), "artifact list should still require a current session")
        try expect(!DockContentRouting.canShow(.artifactViewer, sessionID: ""), "artifact viewer should still require a current session")
        try expect(DockContentRouting.canShow(.artifactList, sessionID: "qm-demo"), "artifact list should open with a current session")
        try expect(DockContentRouting.canShow(.workerChat, sessionID: "qm-demo"), "worker chat should open for every attached session")
        try expect(!DockContentRouting.canShow(.workerChat, sessionID: nil), "worker chat should still require a current session")
    }

    private static func testArtifactDockCommandSwitchesFromQuests() throws {
        try expect(
            !DockCommandRouting.shouldHideArtifactDock(isDockVisible: false, content: .questList),
            "Cmd-3 should show artifacts when the dock is hidden"
        )
        try expect(
            !DockCommandRouting.shouldHideArtifactDock(isDockVisible: true, content: .questList),
            "Cmd-3 should switch visible quests to artifacts"
        )
        try expect(
            !DockCommandRouting.shouldHideArtifactDock(isDockVisible: true, content: .workerChat),
            "Cmd-3 should switch a visible worker chat to artifacts"
        )
        try expect(
            DockCommandRouting.shouldHideArtifactDock(isDockVisible: true, content: .artifactList),
            "Cmd-3 should hide a visible artifact list"
        )
        try expect(
            DockCommandRouting.shouldHideArtifactDock(isDockVisible: true, content: .artifactViewer),
            "Cmd-3 should hide a visible artifact viewer"
        )
    }

    private static func testDockCoordinatorKeepsNoSessionQuestState() throws {
        let coordinator = DockCoordinator()

        coordinator.showDockContent(.artifactList, sessionID: nil)
        try expect(coordinator.state(for: nil) == .initial, "artifact list should not create no-session dock state")

        coordinator.showDockContent(.questList, sessionID: nil)
        let state = coordinator.state(for: nil)
        try expect(state.dockVisible, "quest list should be visible without a current session")
        try expect(state.dockContent == .questList, "no-session dock should show quests")

        coordinator.recordDockVisibility(false, sessionID: nil)
        try expect(!coordinator.state(for: nil).dockVisible, "hiding no-session quest dock should persist")
    }

    private static func testDockCoordinatorShowsWorkerChatPerSession() throws {
        let coordinator = DockCoordinator()

        coordinator.showDockContent(.workerChat, sessionID: nil)
        try expect(coordinator.state(for: nil) == .initial, "worker chat should not create no-session dock state")

        coordinator.mutate("qm-master") { $0.selectedArtifactID = "artifact-1" }
        coordinator.showDockContent(.workerChat, sessionID: "qm-master")
        let state = coordinator.state(for: "qm-master")
        try expect(state.dockVisible && state.dockContent == .workerChat, "worker chat should open for its session")
        try expect(state.selectedArtifactID == nil, "opening worker chat should clear the artifact selection")
        try expect(coordinator.state(for: "qm-other") == .initial, "worker chat should not leak into another session")
    }

    private static func testNewQuestFooterTextMatchesMode() throws {
        try expect(NewQuestSheetFooterText.text(isEditing: false, submitting: false).isEmpty, "create footer should have no static hint")
        try expect(NewQuestSheetFooterText.text(isEditing: false, submitting: true) == "Creating…", "submitting create footer should say Creating")
        try expect(NewQuestSheetFooterText.text(isEditing: true, submitting: false).isEmpty, "edit footer should have no static hint")
        try expect(NewQuestSheetFooterText.text(isEditing: true, submitting: true) == "Saving…", "submitting edit footer should say Saving")
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

        _ = model.apply(
            SessionViewState(dockContent: .artifactList, selectedArtifactID: screenshot.id, artifactScope: .all),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        _ = model.apply(
            SessionViewState(dockContent: .artifactList, artifactScope: .all),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.artifactModel.selectedArtifactID == screenshot.id, "render refresh should preserve current artifact selection")

        let commandModel = DockPaneModel()
        _ = commandModel.apply(
            SessionViewState(dockContent: .artifactList, artifactScope: .all),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        commandModel.setArtifactFilterQuery("@")
        try expect(
            commandModel.artifactModel.filterSuggestions.map(\.title) == ["@project:", "@type:"],
            "@ should show project and type command suggestions"
        )
        commandModel.setArtifactFilterQuery("@p")
        try expect(
            commandModel.artifactModel.filterSuggestions.map(\.title) == ["@project:"],
            "@p should fuzzy-match the project command"
        )
        try expect(commandModel.handleArtifactFilterCommand(keyCode: 48), "Tab should accept the command suggestion")
        try expect(commandModel.artifactModel.artifactFilterQuery == "@project:", "command accept should keep editing values")
        try expect(commandModel.artifactModel.artifactFilterTokens.isEmpty, "command accept should not create a token")

        commandModel.setArtifactFilterQuery("@project:b")
        try expect(commandModel.acceptArtifactFilterSuggestion(), "accepting a project value should succeed")
        try expect(
            commandModel.artifactModel.artifactFilterTokens == [
                ArtifactFilterToken(kind: .project, value: "repo-b", title: "Beta Repo"),
            ],
            "project value accept should render a project token"
        )
        try expect(commandModel.artifactModel.artifacts == [report, screenshot], "project token should filter rows")

        commandModel.setArtifactFilterQuery("@type:i")
        try expect(commandModel.acceptArtifactFilterSuggestion(), "accepting a type value should succeed")
        try expect(commandModel.artifactModel.artifacts == [screenshot], "project and type tokens should combine")
        try expect(
            commandModel.handleArtifactFilterCommand(keyCode: 51),
            "empty-tail Backspace should remove the previous token"
        )
        try expect(commandModel.artifactModel.artifacts == [report, screenshot], "Backspace should clear the last token filter")
        commandModel.setArtifactFilterQuery("@")
        try expect(commandModel.handleArtifactFilterCommand(keyCode: 53), "Esc should close visible suggestions")
        try expect(!commandModel.artifactModel.filterSuggestionsVisible, "Esc should hide suggestions")
        try expect(!commandModel.handleArtifactFilterCommand(keyCode: 53), "second Esc should fall through for input blur")

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
        try expect(model.artifactModel.artifactFilterQuery == "plan", "leaving All should preserve query filter")
        try expect(model.artifactModel.artifactProjectFilterIDs == Set(["repo-b", "_misc"]), "leaving All should preserve project filters")
        try expect(model.artifactModel.artifactTypeFilterIDs.isEmpty, "leaving All should preserve cleared type filters")
        try expect(model.artifactModel.artifacts == [plan], "session scope should ignore persisted All filters")

        _ = model.apply(
            SessionViewState(dockContent: .artifactList, artifactScope: .all),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.artifactModel.artifacts.isEmpty, "returning to All should reapply persisted filters")

        _ = model.apply(
            SessionViewState(dockContent: .artifactList, artifactScope: .all),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-b"
        )
        try expect(model.artifactModel.artifactFilterQuery.isEmpty, "switching sessions should not leak the previous session's filter query")
        try expect(model.artifactModel.artifactFilterTokens.isEmpty, "switching sessions should not leak the previous session's filter tokens")

        _ = model.apply(
            SessionViewState(
                dockContent: .artifactList,
                artifactScope: .all,
                artifactFilterQuery: "plan",
                artifactFilterTokens: [
                    ArtifactFilterToken(kind: .project, value: "repo-b", title: "Beta Repo"),
                    ArtifactFilterToken(kind: .project, value: "_misc", title: "misc"),
                ]
            ),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.artifactModel.artifactFilterQuery == "plan", "returning to a session should restore its own persisted filter query")
        try expect(
            model.artifactModel.artifactProjectFilterIDs == Set(["repo-b", "_misc"]),
            "returning to a session should restore its own persisted project filters"
        )
        try expect(model.artifactModel.artifacts.isEmpty, "restored filters should reapply to the artifact list")
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
        let app = root.appendingPathComponent("Questmaster.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let macos = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let qm = resources.appendingPathComponent("qm")
        for directory in [workingDirectory, stateRoot, resources, macos] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try writeExecutable("#!/bin/sh\necho qm\n", to: qm)
        let executable = macos.appendingPathComponent("Questmaster")
        try writeExecutable("#!/bin/sh\nexit 0\n", to: executable)

        return AppBackendFixture(
            root: root,
            workingDirectory: workingDirectory,
            stateRoot: stateRoot,
            qm: qm,
            bundle: AppBackendResolver.BundleInfo(bundleURL: app, resourceURL: resources, executableURL: executable),
            environment: [
                "HOME": root.appendingPathComponent("user-home", isDirectory: true).path,
                "PATH": "/usr/bin:/bin",
                "QUESTMASTER_STATE_ROOT": stateRoot.path,
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
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let go = binDirectory.appendingPathComponent("go")
        let internalGo = internalDirectory.appendingPathComponent("launch.go")
        for directory in [workingDirectory, internalDirectory, stateRoot, binDirectory] {
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
            go: go,
            internalGo: internalGo,
            bundle: AppBackendResolver.BundleInfo(bundleURL: executable, resourceURL: nil, executableURL: executable),
            environment: [
                "HOME": root.appendingPathComponent("user-home", isDirectory: true).path,
                "PATH": binDirectory.path,
                "QUESTMASTER_STATE_ROOT": stateRoot.path,
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

    private static func testSessionCoordinatorRunsSuccessCallbackOnlyAfterAck() throws {
        let request = try ServeMutationRequests.questDelete(questID: "qst-1")
        var successes = 0
        let failures = Counter()

        let successfulCoordinator = sessionCoordinator(
            client: StubMutationClient(result: .success(ServeMutationAck(data: nil))),
            failures: failures
        )
        successfulCoordinator.sendMutation(request, label: "delete quest qst-1") {
            successes += 1
        }
        drainMainQueue()
        try expect(successes == 1, "success callback should run after mutation ack")
        try expect(failures.value == 0, "successful mutation should not report failure")

        successes = 0
        failures.value = 0
        let failingCoordinator = sessionCoordinator(
            client: StubMutationClient(result: .failure(StubMutationError())),
            failures: failures
        )
        failingCoordinator.sendMutation(request, label: "delete quest qst-1") {
            successes += 1
        }
        drainMainQueue()
        try expect(successes == 0, "failed mutation should not run success callback")
        try expect(failures.value == 1, "failed mutation should report failure")

        successes = 0
        failures.value = 0
        let switches = Counter()
        let switchingCoordinator = sessionCoordinator(
            client: StubMutationClient(result: .success(ServeMutationAck(data: nil))),
            failures: failures,
            switches: switches
        )
        switchingCoordinator.sendMutation(
            request,
            label: "delete quest qst-1",
            switchToSessionID: "qm-a",
            switchBeforeMutation: true
        ) {
            successes += 1
        }
        drainMainQueue()
        try expect(switches.value == 1, "switch-before mutation should activate terminal first")
        try expect(successes == 1, "switch-before mutation should forward success callback")
        try expect(failures.value == 0, "switch-before mutation should not report failure")
    }

    private static func testDeferredDeleteConfirmationRetainsExecutor() throws {
        let request = try ServeMutationRequests.delete(sessionID: "qm-delete")
        var confirmation: ((Bool) -> Void)?
        var sent = false
        weak var executorReference: TrackerEffectExecutor?

        do {
            let executor = TrackerEffectExecutor(dependencies: .init(
                sendMutation: { _, _, _, _, _, _ in sent = true },
                switchSession: { _ in },
                focusTerminal: {},
                focusTracker: {},
                focusDirection: { _ in false },
                copySessionID: { _ in },
                showStatus: { _ in },
                confirmDelete: { _, completion in confirmation = completion }
            ))
            executorReference = executor
            let effect = TrackerEffect.confirmDeleteThenMutation(TrackerDeletePlan(
                sessionID: "qm-delete",
                mutation: TrackerMutationDispatch(request: request, label: "delete qm-delete")
            ))
            _ = executor.execute(effect)
        }

        try expect(executorReference != nil, "pending confirmation should retain its executor")
        confirmation?(true)
        try expect(sent, "confirmed delete should send its mutation")
    }

    private static func testNewSessionArrowKeysNavigatePathSuggestions() throws {
        let model = NewSessionSheetModel(
            presentation: NewSessionSheetPresentation(
                role: .standalone,
                initialPath: "",
                initialTitle: "",
                initialPrompt: "",
                initialFocus: .path,
                mutationClient: StubMutationClient(result: .failure(StubMutationError())),
                directoryClient: nil,
                modelClient: nil,
                effortClient: nil,
                onSuccess: { _ in }
            ),
            dismiss: {}
        )
        model.state.pathSuggestions = ["/a", "/b", "/c"]
        model.state.highlightedSuggestionIndex = 0

        try expect(model.handle(try keyEvent("", keyCode: 125)), "down arrow should be handled")
        try expect(model.state.highlightedSuggestionIndex == 1, "down arrow should move to the next suggestion")

        try expect(model.handle(try keyEvent("", keyCode: 126)), "up arrow should be handled")
        try expect(model.state.highlightedSuggestionIndex == 0, "up arrow should move to the previous suggestion")

        try expect(model.handle(try keyEvent("", keyCode: 126)), "up arrow should be handled at the top")
        try expect(model.state.highlightedSuggestionIndex == 2, "up arrow should wrap to the last suggestion")

        try expect(model.handle(try keyEvent("", keyCode: 125)), "down arrow should be handled at the bottom")
        try expect(model.state.highlightedSuggestionIndex == 0, "down arrow should wrap to the first suggestion")

        model.state.pathSuggestions = []
        try expect(!model.handle(try keyEvent("", keyCode: 125)), "down arrow should not be consumed without suggestions")
    }

    // The sheet must never carry a model list of its own: it asks the backend
    // for one per agent and role, and re-asks when either changes.
    private static func testNewSessionResolvesModelsPerAgent() throws {
        let client = StubModelClient(models: [
            "claude": [SessionModelOption(id: "opus", label: "opus", note: "alias")],
            "codex": [SessionModelOption(id: "gpt-5.6-sol", label: "gpt-5.6-sol", note: "GPT-5.6 Sol")],
        ], defaults: ["claude": "sonnet", "codex": "gpt-5.6-terra"])
        let model = newSessionSheetModel(modelClient: client, initialFocus: .agent)

        model.present()
        drainMainQueue()
        try expect(client.requests.first?.agent == "claude", "the sheet should resolve models for the initial agent")
        try expect(client.requests.first?.role == "standalone", "a standalone sheet should ask for standalone defaults")
        try expect(client.requests.first?.refresh == false, "the sheet's own resolve on open must not force a refetch")
        try expect(
            model.state.model.modelOptions.contains(where: { $0.id == "opus" }),
            "resolved models should reach the picker"
        )
        try expect(
            model.state.model.selectedModelOption == nil,
            "nothing should be selected until the user picks a model, since the resolved default isn't in this list"
        )
        try expect(model.state.model.selectedModel.isEmpty, "an unselected model sends no override")

        // Cycle the model select onto a real model, then change the agent.
        model.state.model.focusedField = .model
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the model select")
        try expect(model.state.model.selectedModel == "opus", "cycling should select the resolved model")

        model.state.model.focusedField = .agent
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the agent select")
        try expect(
            model.state.model.selectedModel.isEmpty,
            "another harness's model must not carry over"
        )
        drainMainQueue()
        try expect(client.requests.last?.agent == "codex", "changing the agent should re-resolve models")
        try expect(
            model.state.model.modelOptions.contains(where: { $0.id == "gpt-5.6-sol" }),
            "the new agent's models should replace the previous list"
        )

        // Returning to an agent already resolved this sheet session must
        // apply instantly from cache, not re-ask the backend.
        let requestsBeforeReturn = client.requests.count
        try expect(model.handle(try keyEvent("h", keyCode: 4)), "h should cycle the agent select back")
        try expect(model.state.model.selectedAgent == "claude", "precondition: back to claude")
        drainMainQueue()
        try expect(
            client.requests.count == requestsBeforeReturn,
            "returning to an already-resolved agent must not re-ask the backend"
        )
        try expect(
            model.state.model.modelOptions.contains(where: { $0.id == "opus" }),
            "the cached list should apply instantly"
        )
    }

    private static func testNewSessionKeepsDefaultModelWhenResolveFails() throws {
        let client = StubModelClient(models: [:], defaults: [:], failing: true)
        let model = newSessionSheetModel(modelClient: client, initialFocus: .path)

        model.present()
        drainMainQueue()

        // A failed resolve is not the user's problem: no options at all
        // still starts a session with no model override.
        try expect(model.state.model.modelOptions.isEmpty, "a failed resolve should leave no options")
        try expect(model.state.model.selectedModel.isEmpty, "a failed resolve should send no model override")
        try expect(model.state.model.errorMessage == nil, "a failed resolve should not raise a form error")
    }

    // The `r` key is the model picker's own refresh shortcut — it must reach
    // the backend with refresh:true (bypassing the catalog cache) and only
    // while the Model field is actually focused.
    private static func testNewSessionRefreshModelsKeyForcesARefetch() throws {
        let client = StubModelClient(
            models: ["claude": [SessionModelOption(id: "opus", label: "opus")]],
            defaults: ["claude": "sonnet"]
        )
        let model = newSessionSheetModel(modelClient: client, initialFocus: .model)

        model.present()
        drainMainQueue()

        try expect(
            model.handle(try keyEvent("r", keyCode: 15)),
            "r should be consumed while the model field is focused"
        )
        drainMainQueue()
        try expect(client.requests.last?.refresh == true, "r should force a refetch past the catalog cache")

        model.state.model.focusedField = .agent
        let requestsBeforeAgentR = client.requests.count
        try expect(
            !model.handle(try keyEvent("r", keyCode: 15)),
            "r should not be claimed by the sheet outside the model field"
        )
        drainMainQueue()
        try expect(
            client.requests.count == requestsBeforeAgentR,
            "r on another field must not trigger a model refetch"
        )
    }

    // The refresh button's disabled/dimmed state is driven by isRefreshingModels,
    // which must be true only for the duration of an in-flight refresh.
    private static func testNewSessionRefreshModelsButtonTracksInFlightState() throws {
        let client = StubModelClient(
            models: ["claude": [SessionModelOption(id: "opus", label: "opus")]],
            defaults: ["claude": "sonnet"]
        )
        let model = newSessionSheetModel(modelClient: client, initialFocus: .model)

        model.present()
        drainMainQueue()
        try expect(!model.state.isRefreshingModels, "the sheet's own resolve on open should not show as refreshing")

        model.refreshModels()
        try expect(model.state.isRefreshingModels, "a refresh should show as in-flight immediately")
        drainMainQueue()
        try expect(!model.state.isRefreshingModels, "the flag should clear once the refresh completes")
        try expect(client.requests.last?.refresh == true, "the refresh button should force a refetch")
    }

    // The modelRequestID guard exists precisely for this: an earlier
    // request's response arriving *after* a newer one must be discarded, not
    // applied on top of it. StubModelClient's deferred-completion mode lets
    // this test fire them in the opposite order from how they were called.
    private static func testNewSessionDiscardsStaleModelResponseArrivingAfterANewerOne() throws {
        let staleModel = SessionModelOption(id: "opus-initial", label: "opus-initial")
        let freshModel = SessionModelOption(id: "opus-refreshed", label: "opus-refreshed")
        let client = StubModelClient(deferCompletions: true, sequencedModels: [[staleModel], [freshModel]])
        let model = newSessionSheetModel(modelClient: client, initialFocus: .model)

        model.present()
        model.refreshModels()
        try expect(client.requests.count == 2, "present and refreshModels should each fire one request")

        // Fire the newer (refresh) request first, then the stale initial one
        // — the opposite of call order.
        client.fireCompletion(forRequestAt: 1)
        drainMainQueue()
        try expect(
            model.state.model.modelOptions.contains(where: { $0.id == "opus-refreshed" }),
            "the newer response should apply"
        )
        try expect(!model.state.isRefreshingModels, "the newer (refresh) request completing should clear the flag")

        client.fireCompletion(forRequestAt: 0)
        drainMainQueue()
        try expect(
            !model.state.model.modelOptions.contains(where: { $0.id == "opus-initial" }),
            "a stale response arriving after a newer one must be discarded, not applied on top of it"
        )
        try expect(
            model.state.model.modelOptions.contains(where: { $0.id == "opus-refreshed" }),
            "the newer response must still stand after the stale one arrives"
        )
    }

    // Mirrors testNewSessionResolvesModelsPerAgent: the sheet must never carry
    // a reasoning-effort list of its own, and re-asks whenever agent, role, or
    // model changes — model matters here because Codex/OpenCode's valid
    // levels depend on which model is selected.
    private static func testNewSessionResolvesReasoningEffortsPerAgentAndModel() throws {
        let effortClient = StubReasoningEffortClient(
            efforts: ["claude": ["low", "medium", "high", "xhigh", "max"], "gpt-5.6-sol": ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]],
            defaults: ["claude": "xhigh", "gpt-5.6-sol": "xhigh"]
        )
        let modelClient = StubModelClient(
            models: ["codex": [SessionModelOption(id: "gpt-5.6-sol", label: "gpt-5.6-sol")]],
            defaults: ["claude": "sonnet", "codex": "gpt-5.6-terra"]
        )
        let model = newSessionSheetModel(modelClient: modelClient, effortClient: effortClient, initialFocus: .agent)

        model.present()
        drainMainQueue()
        try expect(effortClient.requests.first?.agent == "claude", "the sheet should resolve efforts for the initial agent")
        try expect(effortClient.requests.first?.model.isEmpty == true, "the default entry sends no model override to resolve against")
        try expect(
            model.state.model.effortOptions.contains(where: { $0.id == "low" }),
            "resolved efforts should reach the picker"
        )
        try expect(
            model.state.model.selectedReasoningEffort == "xhigh",
            "the resolved default should seed the selection, since it's a member of the resolved list"
        )
        try expect(
            model.state.model.effortOptions.contains(where: { $0.id == "xhigh" }),
            "levels are never filtered or deduped against the default"
        )

        // Cycling onto a real model (still the same agent/role) must
        // re-resolve efforts against that model.
        model.state.model.focusedField = .agent
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the agent select")
        drainMainQueue()
        model.state.model.focusedField = .model
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the model select")
        drainMainQueue()
        try expect(model.state.model.selectedModel == "gpt-5.6-sol", "precondition: a real model is selected")
        try expect(effortClient.requests.last?.model == "gpt-5.6-sol", "selecting a model should re-resolve efforts against it")
        try expect(
            model.state.model.effortOptions.contains(where: { $0.id == "ultra" }),
            "the model-specific effort tier should reach the picker"
        )
    }

    private static func testNewSessionKeepsDefaultReasoningEffortWhenResolveFails() throws {
        let model = newSessionSheetModel(modelClient: nil, effortClient: nil, initialFocus: .path)

        model.present()
        drainMainQueue()

        // No client at all is the same shape as a failed resolve: no options
        // at all still starts a session with no effort override.
        try expect(model.state.model.effortOptions.isEmpty, "no client should leave no options")
        try expect(model.state.model.selectedReasoningEffort.isEmpty, "an unresolved picker should send no effort override")
    }

    // The app-launched qm serve can take a few seconds to bind its socket
    // (ServeProcess.waitForSocket), and this client has no reconnect loop of
    // its own — a New Session sheet opened in that window must not just fail
    // once and sit stuck on the default entry forever.
    private static func testConnectWithRetryRetriesUntilConnectSucceeds() throws {
        var attempts = 0
        var sleeps: [TimeInterval] = []
        let fd = try UnixSocketMutationClient.connectWithRetry(
            socketPath: "unused",
            connect: { _ in
                attempts += 1
                if attempts < 3 {
                    throw ServeClientError.connect("not ready yet")
                }
                return 42
            },
            sleep: { sleeps.append($0) }
        )
        try expect(fd == 42, "should return the fd from the attempt that finally succeeded")
        try expect(attempts == 3, "should retry past two failures instead of giving up after the first")
        try expect(sleeps == [0.15, 0.3], "should wait using the schedule between the two failed attempts")
    }

    private static func testConnectWithRetryGivesUpAfterExhaustingTheSchedule() throws {
        var attempts = 0
        var thrown: Error?
        do {
            _ = try UnixSocketMutationClient.connectWithRetry(
                socketPath: "unused",
                connect: { _ in
                    attempts += 1
                    throw ServeClientError.connect("still not ready")
                },
                sleep: { _ in }
            )
        } catch {
            thrown = error
        }
        try expect(attempts == UnixSocketMutationClient.connectRetryDelays.count, "should give up only after exhausting every scheduled attempt")
        try expect(thrown != nil, "should propagate the last connect failure once retries are exhausted")
    }

    // Effort has no row of its own: `e` must cycle it while the Model field
    // is focused, and must not be claimed anywhere else (it would otherwise
    // collide with typing "e" into a text field, or another select's own
    // shortcuts).
    private static func testNewSessionEffortKeyCyclesWhileModelFocused() throws {
        let effortClient = StubReasoningEffortClient(
            efforts: ["claude": ["low", "high"]],
            defaults: ["claude": "xhigh"]
        )
        let model = newSessionSheetModel(modelClient: nil, effortClient: effortClient, initialFocus: .model)

        model.present()
        drainMainQueue()
        try expect(model.state.model.selectedEffortOption == nil, "precondition: nothing selected, since xhigh isn't in this resolved list")

        try expect(
            model.handle(try keyEvent("e", keyCode: 14)),
            "e should be consumed while the model field is focused"
        )
        try expect(model.state.model.selectedReasoningEffort == "low", "e should cycle to the first resolved level")

        model.state.model.focusedField = .agent
        try expect(
            !model.handle(try keyEvent("e", keyCode: 14)),
            "e should not be claimed by the sheet outside the model field"
        )
    }

    private static func newSessionSheetModel(
        modelClient: ServeModelSuggesting?,
        effortClient: ServeReasoningEffortSuggesting? = nil,
        initialFocus: NewSessionField
    ) -> NewSessionSheetModel {
        NewSessionSheetModel(
            presentation: NewSessionSheetPresentation(
                role: .standalone,
                initialPath: "/tmp/project",
                initialTitle: "",
                initialPrompt: "",
                initialFocus: initialFocus,
                mutationClient: StubMutationClient(result: .failure(StubMutationError())),
                directoryClient: nil,
                modelClient: modelClient,
                effortClient: effortClient,
                onSuccess: { _ in }
            ),
            dismiss: {}
        )
    }

    // Guards the live-apply contract: cycling a value sends its
    // role_default.set the moment it changes, with no confirm/done step.
    private static func testSettingsCyclingAFieldSendsItsRoleDefaultImmediately() throws {
        let modelClient = StubModelClient(
            models: ["claude": [
                SessionModelOption(id: "opus", label: "opus"),
                SessionModelOption(id: "sonnet", label: "sonnet"),
            ]],
            defaults: ["claude": "opus"]
        )
        let effortClient = StubReasoningEffortClient(
            efforts: ["claude": ["low", "high"]],
            defaults: ["claude": "low"]
        )
        let mutationClient = StubMutationClient(result: .success(ServeMutationAck(data: nil)))
        let model = settingsSheetModel(mutationClient: mutationClient, modelClient: modelClient, effortClient: effortClient)
        model.state = RoleDefaultsSettingsModel(agents: ["claude"])

        model.present()
        drainMainQueue()
        try expect(mutationClient.sentRequests.isEmpty, "resolving options alone must send nothing")

        model.focus(role: "master", field: .model)
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the model select")
        drainMainQueue()

        try expect(mutationClient.sentRequests.count == 1, "cycling a value should send its role_default.set immediately")
        guard let sent = mutationClient.sentRequests.first else {
            throw TestFailure("expected a role_default.set send")
        }
        try expect(sent.data["agent"] == "claude" && sent.data["role"] == "master", "should send the row that was actually cycled")
        try expect(sent.data["model"] == "sonnet", "should send the newly cycled value")
    }

    // With no Done button left, closing the sheet must never block on
    // whatever role_default.set sends are still in flight.
    private static func testSettingsCloseDoesNotWaitForInFlightSaves() throws {
        let modelClient = StubModelClient(
            models: ["claude": [
                SessionModelOption(id: "opus", label: "opus"),
                SessionModelOption(id: "sonnet", label: "sonnet"),
            ]],
            defaults: ["claude": "opus"]
        )
        let mutationClient = StubMutationClient(result: .success(ServeMutationAck(data: nil)), deferCompletions: true)
        var dismissed = false
        let model = settingsSheetModel(mutationClient: mutationClient, modelClient: modelClient, dismiss: { dismissed = true })
        model.state = RoleDefaultsSettingsModel(agents: ["claude"])

        model.present()
        drainMainQueue()
        model.focus(role: "master", field: .model)
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the model select")
        try expect(mutationClient.sentRequests.count == 1, "sanity: cycling sent one save that's still in flight")
        try expect(!dismissed, "sanity: not dismissed yet")

        try expect(model.handle(try keyEvent("\u{1B}", keyCode: 53)), "esc should be handled")
        try expect(dismissed, "esc should close the sheet immediately, without waiting on the in-flight save")
    }

    // A failed save must surface an error instead of silently dropping it,
    // and must not get marked as saved (or the app would show a value the
    // backend never actually persisted).
    private static func testSettingsFailedSaveSurfacesErrorMessage() throws {
        let modelClient = StubModelClient(
            models: ["claude": [
                SessionModelOption(id: "opus", label: "opus"),
                SessionModelOption(id: "sonnet", label: "sonnet"),
            ]],
            defaults: ["claude": "opus"]
        )
        let mutationClient = StubMutationClient(result: .failure(StubMutationError()))
        let model = settingsSheetModel(mutationClient: mutationClient, modelClient: modelClient)
        model.state = RoleDefaultsSettingsModel(agents: ["claude"])

        model.present()
        drainMainQueue()
        model.focus(role: "master", field: .model)
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the model select")
        drainMainQueue()

        try expect(model.errorMessage != nil, "a failed save must surface an error instead of silently dropping it")
        try expect(model.state.rows[0].isDirty, "a failed save must not get marked as saved")
    }

    // Guards a real bug found in review: the user can keep editing while a
    // role_default.set save is still in flight. Firing an independent send on
    // every cycle (instead of batching behind a confirm step) means a newer
    // edit is never silently dropped, regardless of the order acks land in.
    private static func testSettingsResendsAnEditMadeWhileAPreviousSaveIsInFlight() throws {
        let modelClient = StubModelClient(
            models: ["claude": [
                SessionModelOption(id: "opus", label: "opus"),
                SessionModelOption(id: "sonnet", label: "sonnet"),
                SessionModelOption(id: "haiku", label: "haiku"),
            ]],
            defaults: ["claude": "opus"]
        )
        let mutationClient = StubMutationClient(result: .success(ServeMutationAck(data: nil)), deferCompletions: true)
        let model = settingsSheetModel(mutationClient: mutationClient, modelClient: modelClient)
        model.state = RoleDefaultsSettingsModel(agents: ["claude"])

        model.present()
        drainMainQueue()
        try expect(model.state.rows[0].selectedModel == "opus", "sanity: seeded onto the persisted default")

        model.focus(role: "master", field: .model)
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle to the next model")
        try expect(model.state.rows[0].selectedModel == "sonnet", "sanity: cycled to a new value")
        try expect(mutationClient.sentRequests.count == 1, "cycling should send immediately")
        try expect(mutationClient.sentRequests[0].data["model"] == "sonnet", "should send the value just cycled to")

        // The user keeps editing while that save is still in flight.
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle again before the first save acks")
        try expect(model.state.rows[0].selectedModel == "haiku", "sanity: a newer, independently-sent edit")
        try expect(mutationClient.sentRequests.count == 2, "the newer edit must be sent too, not silently dropped")
        try expect(mutationClient.sentRequests[1].data["model"] == "haiku", "the second send should carry the newer value")

        // Acks land out of order: the newer send's ack arrives first.
        mutationClient.fireCompletion(forRequestAt: 1)
        drainMainQueue()
        mutationClient.fireCompletion(forRequestAt: 0)
        drainMainQueue()

        try expect(model.errorMessage == nil, "both saves succeeding should leave no error")
    }

    /// A fractional footer height puts every plate border and the snapped terminal edge on half
    /// pixels at 1x, which renders blurry — guards `ActionBarMetrics.footerHeight` against a
    /// future edit reintroducing a fractional sum.
    private static func testActionBarFooterHeightIsIntegral() throws {
        try expect(
            ActionBarMetrics.footerHeight == ActionBarMetrics.footerHeight.rounded(),
            "footerHeight should be a whole point, got \(ActionBarMetrics.footerHeight)"
        )
    }

    /// The slot run is centred on the frame, and the bar's hit area sits inside the footer.
    private static func testActionBarSlotsCentreInsideFooter() throws {
        let runStart = ActionBarMetrics.slotX(at: 0)
        let runEnd = ActionBarMetrics.slotX(at: ActionBarMetrics.slotCount - 1) + ActionBarMetrics.slotSize
        try expect(
            (runStart + runEnd) / 2 == ActionBarMetrics.plateWidth / 2,
            "slot run should centre on the frame, got centre \((runStart + runEnd) / 2)"
        )
        try expect(
            ActionBarMetrics.barHitRect.minY >= 0 && ActionBarMetrics.barHitRect.maxY <= ActionBarMetrics.footerHeight,
            "bar hit area should sit inside the footer, got \(ActionBarMetrics.barHitRect)"
        )
    }

    /// Root cause of the scrollbar gutter resisting four prior fix PRs (#222/#223/#225/#226):
    /// hiding the scroller once from SwiftUI's `updateNSView` only reapplies when SwiftUI itself
    /// re-renders. AppKit resets `NSScrollView.scrollerStyle` independently whenever
    /// `NSScroller.preferredScrollerStyleDidChangeNotification` fires (e.g. a mouse connects while
    /// "Show scroll bars" is Automatic), so the gutter can return with no SwiftUI state change to
    /// trigger a reapply. `ScrollerHidingNSView` observes that notification directly instead.
    ///
    /// AppKit's own response to that same notification isn't guaranteed to land before or after
    /// ours, so reapplying directly inside the notification handler can still race it: if ours
    /// runs first, an AppKit reset landing right behind it re-breaks the gutter with nothing left
    /// to react to it. `NotificationCenter` doesn't document how it orders multiple observers of
    /// one notification, so the stand-in for AppKit's reset below doesn't rely on that: it's
    /// plain, unconditionally-sequential code run right after `post()` returns, not a second
    /// observer racing the first. A single-hop reapply can only "win" that race by having already
    /// run *during* `post()`, before this stand-in gets to run at all; the deferred fix wins
    /// regardless, by running on the *next* main-runloop turn instead — after the stand-in, not
    /// racing it.
    private static func testScrollerHidingSurvivesCompetingResetQueuedRightBehindIt() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy

        let hider = ScrollerHidingNSView()
        documentView.addSubview(hider)

        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        try expect(
            scrollView.contentView.bounds.width == scrollView.bounds.width,
            "clip view should fill the scroll view width once the scroller is hidden, got \(scrollView.contentView.bounds.width) of \(scrollView.bounds.width)"
        )

        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        // Plain synchronous code, right after `post()` returns — the stand-in for AppKit's own
        // reset, landing deterministically before any run-loop turn gets pumped below.
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.tile()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        try expect(
            scrollView.contentView.bounds.width == scrollView.bounds.width,
            "clip view should still fill the scroll view width after a competing reset lands right behind the style-change notification, got \(scrollView.contentView.bounds.width) of \(scrollView.bounds.width)"
        )
    }

    /// Follower fixture: a flipped document in an offscreen window, so the clip origin reads like the
    /// real feed (bottom = content - viewport). Tests wait for the state they need with `waitUntil`,
    /// and assert a glide as it is added. Nothing here waits for an animation to finish.
    @MainActor
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    @MainActor
    private struct FollowerFixture {
        let window: NSWindow
        let scrollView: NSScrollView
        let documentView: NSView
        let follower: WorkerChatBottomFollowerView

        var origin: CGFloat { scrollView.contentView.bounds.origin.y }

        /// A layout of a document `height` tall, with its rows filling the padded height, as the feed lays out.
        func grow(to height: CGFloat) {
            show(rows: height - 2 * WorkerChatMetrics.inset)
        }

        /// Lays `rows` out the way the feed does, then runs the follower on the result. The fixture reads the
        /// state the layout just produced, so nothing here waits on a notification or an animation.
        func show(rows: CGFloat) {
            layout(rows: rows)
            follower.sync(scrollView)
        }

        /// Sets the frames only: the document is at least a viewport tall, and the rows sit at its bottom, so a
        /// short feed keeps the document's height while its rows move.
        func layout(rows: CGFloat) {
            let width = documentView.frame.width
            let height = max(rows + 2 * WorkerChatMetrics.inset, scrollView.contentView.bounds.height)
            documentView.setFrameSize(NSSize(width: width, height: height))
            follower.frame = NSRect(x: 0, y: height - WorkerChatMetrics.inset - rows, width: width, height: rows)
        }

        func scroll(to offset: CGFloat) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            follower.sync(scrollView)
        }

        func resize(height: CGFloat) {
            scrollView.setFrameSize(NSSize(width: scrollView.frame.width, height: height))
            follower.sync(scrollView)
        }
    }

    /// A feed `contentHeight` tall whose rows are `rows` tall (the padded height by default), bottom-aligned.
    private static func followerFixture(contentHeight: CGFloat, rows: CGFloat? = nil) -> FollowerFixture {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let documentView = FlippedDocumentView(frame: NSRect(x: 0, y: 0, width: 300, height: contentHeight))
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = false
        let follower = WorkerChatBottomFollowerView()
        let rowsHeight = rows ?? contentHeight - 2 * WorkerChatMetrics.inset
        follower.frame = NSRect(x: 0, y: contentHeight - WorkerChatMetrics.inset - rowsHeight, width: 300, height: rowsHeight)
        documentView.addSubview(follower)
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = scrollView
        window.orderFrontRegardless()
        holdMotion(scrollView, true)
        return FollowerFixture(window: window, scrollView: scrollView, documentView: documentView, follower: follower)
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Stops or restarts the clock for `view`'s layer tree. While it is stopped, a glide or fade holds its start
    /// for as long as the run loop runs, so a check never races an animation that has run out on a slow host.
    /// Restarting the clock runs the held animations from where they stopped.
    private static func holdMotion(_ view: NSView, _ held: Bool) {
        view.layer?.speed = held ? 0 : 1
    }

    /// Pumps the run loop until `condition` holds, for at most five seconds, and reports whether it did.
    /// The name must start at its column past the logo in a proportional chat font too. A Ghostty family can be
    /// proportional, where the lead's space is narrower than the font's widest glyph.
    private static func testWorkerChatNameStartsPastLogoInAnyChatFont() throws {
        let fonts: [(label: String, chat: NSFont, name: NSFont)] = [
            ("monospace", AppFonts.chat, AppFonts.chatName),
            ("proportional", .systemFont(ofSize: 12), .systemFont(ofSize: 12, weight: .bold)),
        ]
        let expectedNameX = WorkerChatMetrics.timeColumnWidth + WorkerChatMetrics.logoColumnWidth
        for font in fonts {
            let nameX = try nameInkX(chatFont: font.chat, nameFont: font.name)
            try expect(abs(nameX - expectedNameX) <= 1, "the name should start at x \(expectedNameX) with a \(font.label) chat font, got \(nameX)")
        }
    }

    /// The x in points of the first ink right of the logo column, drawn by the line view alone. The name is one
    /// glyph, so the first ink is where the name starts: a gap between letters can't hide it.
    private static func nameInkX(chatFont: NSFont, nameFont: NSFont) throws -> CGFloat {
        let width: CGFloat = 300
        let height = WorkerChatMetrics.lineHeight
        let line = WorkerChatLine(id: "name", time: "08:20", agent: "codex", segments: [
            WorkerChatSegment("I", .name),
        ])
        let hosting = NSHostingView(rootView: WorkerChatLineView(line: line, chatFont: chatFont, nameFont: nameFont)
            .frame(width: width, height: height, alignment: .topLeading))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw TestFailure("the line view should capture to a bitmap")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / width
        let logoEnd = WorkerChatMetrics.timeColumnWidth + WorkerChatMetrics.logoColumnWidth
        for pixelX in Int(logoEnd * scale)..<bitmap.pixelsWide {
            let hasInk = (0..<bitmap.pixelsHigh).contains { pixelY in
                (bitmap.colorAt(x: pixelX, y: pixelY)?.alphaComponent ?? 0) > 0
            }
            if hasInk {
                return CGFloat(pixelX) / scale
            }
        }
        throw TestFailure("the name should draw past the logo")
    }

    private static func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            pump(0.005)
        }
        return true
    }

    private static func hasGlide(_ view: NSView) -> Bool {
        !(view.layer?.animationKeys() ?? []).isEmpty
    }

    /// Checks the glide that was added on `view`. It reads the layer now, so call it right after the layout that
    /// added the glide, before any run-loop wait.
    private static func expectGlideAdded(on view: NSView, startsBetween low: CGFloat, and high: CGFloat) throws {
        guard let glide = view.layer?.animation(forKey: WorkerChatMotion.glideKey) as? CABasicAnimation else {
            throw TestFailure("an arrival should add the glide animation under its key")
        }
        try expectGlide(glide, on: view, startsBetween: low, and: high)
    }

    /// Checks a glide: a y translation from a start in the given range to zero, lasting the glide duration,
    /// with the model transform on `view` left at identity.
    private static func expectGlide(_ glide: CABasicAnimation, on view: NSView, startsBetween low: CGFloat, and high: CGFloat) throws {
        try expect(glide.keyPath == "transform.translation.y", "the glide should move the document's y translation, got \(String(describing: glide.keyPath))")
        try expect((glide.toValue as? NSNumber)?.doubleValue == 0, "the glide should end at zero, got \(String(describing: glide.toValue))")
        let start = (glide.fromValue as? NSNumber)?.doubleValue ?? .nan
        try expect(start >= low - 0.001 && start <= high + 0.001, "the glide should start between \(low) and \(high) points, got \(start)")
        try expect(glide.duration == WorkerChatMotion.glideDuration, "the glide should last \(WorkerChatMotion.glideDuration)s, got \(glide.duration)")
        try expect(CATransform3DIsIdentity(view.layer?.transform ?? CATransform3DIdentity), "the model transform should stay at identity while the glide runs")
    }

    /// A line arriving while the feed follows glides in, and a second arrival mid-glide keeps the
    /// follower at the bottom. Only the clip bounds decide follow state, and they never animate.
    private static func testWorkerChatFollowerGlidesArrivalsAndKeepsFollowingMidGlide() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        try expect(waitUntil { fixture.origin == 800 }, "a fresh feed should pin to the bottom, got \(fixture.origin)")
        try expect(fixture.follower.isFollowing, "a fresh feed should follow")
        try expect(!hasGlide(fixture.documentView), "the first layout should not glide")

        fixture.grow(to: 1026)
        try expect(waitUntil { fixture.origin == 826 }, "an arrival should move the clip to the new bottom at once, got \(fixture.origin)")
        try expectGlideAdded(on: fixture.documentView, startsBetween: 26, and: 26)

        fixture.grow(to: 1052)
        try expect(waitUntil { fixture.origin == 852 }, "a second arrival mid-glide should still pin, got \(fixture.origin)")
        try expect(fixture.follower.isFollowing, "a line arriving mid-glide should keep following")
        try expectGlideAdded(on: fixture.documentView, startsBetween: 26, and: 52)
    }

    /// A trim pins to the bottom without a glide, and the next arrival still glides. A viewport resize
    /// pins without a glide too. It runs on its own fixture, since a glide from an arrival may still
    /// be in flight.
    private static func testWorkerChatFollowerDoesNotGlideOnTrimOrResize() throws {
        let trimmed = followerFixture(contentHeight: 1000)
        defer { trimmed.window.close() }
        try expect(waitUntil { trimmed.origin == 800 }, "a fresh feed should pin to the bottom, got \(trimmed.origin)")
        trimmed.follower.noteLinesUpdate(revision: 1, trimCount: 1, appended: false)
        trimmed.grow(to: 974)
        try expect(waitUntil { trimmed.origin == 774 }, "a trim with shorter wrapped rows should pin to the bottom, got \(trimmed.origin)")
        try expect(!hasGlide(trimmed.documentView), "a trim update should not glide")
        try expect(trimmed.follower.isFollowing, "a trim update should keep following")

        trimmed.follower.noteLinesUpdate(revision: 2, trimCount: 1, appended: false)
        trimmed.grow(to: 1000)
        try expect(waitUntil { hasGlide(trimmed.documentView) }, "an arrival after the trim update should glide again")

        let resized = followerFixture(contentHeight: 1000)
        defer { resized.window.close() }
        try expect(waitUntil { resized.origin == 800 }, "a fresh feed should pin to the bottom, got \(resized.origin)")
        resized.resize(height: 240)
        try expect(waitUntil { resized.origin == 760 }, "a resize should pin to the new bottom, got \(resized.origin)")
        try expect(!hasGlide(resized.documentView), "a viewport resize should not glide")
        try expect(resized.follower.isFollowing, "a resize should keep following")
    }

    /// A trim that leaves the content height unchanged never reaches a height callback. The flag must
    /// still not outlive that update: the next arrival glides.
    private static func testWorkerChatEqualHeightTrimDoesNotSkipTheNextArrivalGlide() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        try expect(waitUntil { fixture.origin == 800 }, "a fresh feed should pin to the bottom, got \(fixture.origin)")

        fixture.follower.noteLinesUpdate(revision: 1, trimCount: 1, appended: false)
        fixture.follower.noteLinesUpdate(revision: 2, trimCount: 1, appended: false)
        fixture.grow(to: 1026)
        try expect(waitUntil { fixture.origin == 826 }, "the arrival should pin to the bottom, got \(fixture.origin)")
        try expectGlideAdded(on: fixture.documentView, startsBetween: 26, and: 26)
    }

    /// SwiftUI can render one lines update twice before its layout. The second render must not clear
    /// the trim flag, or the trim's layout would glide.
    private static func testWorkerChatRepeatedRenderBeforeLayoutKeepsTrimSuppressed() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        try expect(waitUntil { fixture.origin == 800 }, "a fresh feed should pin to the bottom, got \(fixture.origin)")

        fixture.follower.noteLinesUpdate(revision: 1, trimCount: 1, appended: false)
        fixture.follower.noteLinesUpdate(revision: 1, trimCount: 1, appended: false)
        fixture.grow(to: 974)
        try expect(waitUntil { fixture.origin == 774 }, "the trim should pin to the bottom, got \(fixture.origin)")
        try expect(!hasGlide(fixture.documentView), "a trim should not glide even when rendered twice before layout")
    }

    /// The real feed, through SwiftUI's update path: a trim with wrapped rows (the content height
    /// drops by an amount no single row explains) pins without a glide, and the next arrival glides.
    private static func testWorkerChatTrimWithWrappedRowsSkipsGlide() throws {
        let hosting = NSHostingView(rootView: wrappedFeed(count: 30, revision: 1, trimCount: 0, appended: false))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        try expect(waitUntil { descendant(NSScrollView.self, in: hosting) != nil }, "the worker chat feed should host a scroll view")
        guard let scrollView = descendant(NSScrollView.self, in: hosting),
              let follower = descendant(WorkerChatBottomFollowerView.self, in: hosting),
              let documentView = scrollView.documentView else {
            throw TestFailure("the worker chat feed should host a scroll view and its follower")
        }
        holdMotion(scrollView, true)
        let viewport = { scrollView.contentView.bounds.height }
        let bottom = { documentView.frame.height - viewport() }
        try expect(waitUntil { documentView.frame.height > viewport() }, "the first layout should fill the feed")
        try expect(waitUntil { abs(scrollView.contentView.bounds.origin.y - bottom()) < 1 }, "the first layout should pin to the bottom")
        try expect(follower.isFollowing, "a fresh feed should follow")
        try expect(!hasGlide(documentView), "the first layout should not glide")

        let heightBeforeTrim = documentView.frame.height
        hosting.rootView = wrappedFeed(count: 22, revision: 2, trimCount: 1, appended: false)
        try expect(waitUntil { documentView.frame.height < heightBeforeTrim }, "the trim should shorten the content")
        try expect(waitUntil { abs(scrollView.contentView.bounds.origin.y - bottom()) < 1 }, "a trim should pin to the new bottom")
        try expect(!hasGlide(documentView), "a wrapped-row trim should not glide")
        try expect(follower.isFollowing, "a trim should keep following")

        hosting.rootView = wrappedFeed(count: 23, revision: 3, trimCount: 1, appended: true)
        try expect(waitUntil { hasGlide(documentView) }, "an arrival after the trim should glide")
    }

    /// Every third entry wraps to several lines at the 300pt test width, unless `wraps` is false. The line count
    /// depends on the font, so a test that needs a feed to stay short passes `wraps: false`.
    private static func wrappedFeed(count: Int, revision: Int, trimCount: Int, appended: Bool, wraps: Bool = true) -> some View {
        let wrapped = String(repeating: "wrapped words in a long line ", count: 6)
        let lines = (0..<count).map { index in
            WorkerChatLine(id: "e\(index)", time: "09:00", agent: "claude", segments: [
                WorkerChatSegment("Worker One:", .name),
                WorkerChatSegment(" \(index) \(wraps && index % 3 == 0 ? wrapped : "short")", .normal),
            ])
        }
        return WorkerChatFeedView(lines: lines, revision: revision, trimCount: trimCount, appended: appended).frame(width: 300, height: 200)
    }

    /// Finds the first descendant of `type`, for the SwiftUI-hosted feed.
    private static func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T {
            return match
        }
        for subview in view.subviews {
            if let match = descendant(type, in: subview) {
                return match
            }
        }
        return nil
    }

    /// Checks the fade on a band. It reads the band now, so call it right after the layout that added the fade.
    private static func expectFadeAdded(on band: CALayer) throws {
        guard let fade = band.animation(forKey: WorkerChatMotion.enterKey) as? CABasicAnimation else {
            throw TestFailure("a fade band should carry its fade under the enter key")
        }
        try expectFade(fade, on: band)
    }

    /// Checks a fade: opacity from transparent to opaque over the enter duration. The model stays opaque, so
    /// the rows are fully visible once the fade is gone.
    private static func expectFade(_ fade: CABasicAnimation, on band: CALayer) throws {
        try expect(fade.keyPath == "opacity", "the fade should animate opacity, got \(String(describing: fade.keyPath))")
        try expect((fade.fromValue as? NSNumber)?.doubleValue == 0, "the fade should start transparent, got \(String(describing: fade.fromValue))")
        try expect((fade.toValue as? NSNumber)?.doubleValue == 1, "the fade should end opaque, got \(String(describing: fade.toValue))")
        try expect(fade.duration == WorkerChatMotion.enterDuration, "the fade should last \(WorkerChatMotion.enterDuration)s, got \(fade.duration)")
        try expect(band.opacity == 1, "the band's model opacity should stay opaque, got \(band.opacity)")
    }

    /// A band must cover exactly the document rows from `top` to `bottom`.
    private static func expectBand(_ band: CALayer, from top: CGFloat, to bottom: CGFloat) throws {
        try expect(
            abs(band.frame.minY - top) < 0.5 && abs(band.frame.maxY - bottom) < 0.5,
            "the band should cover document rows \(top) to \(bottom), got \(band.frame)"
        )
    }

    /// The fade bands on a document's mask, in the order they were added.
    private static func fadeBands(on view: NSView) -> [CALayer] {
        Array(view.layer?.mask?.sublayers?.dropFirst() ?? [])
    }

    /// The opaque base on a document's mask, which covers everything above the first band.
    private static func maskBase(on view: NSView) -> CALayer? {
        view.layer?.mask?.sublayers?.first
    }

    /// Where each drawn content layer under `layer` sits, in `layer`'s own coordinates. The rows are
    /// drawn into layers like these, so their frames show where the rows are.
    private static func contentFrames(in layer: CALayer?) -> [CGRect] {
        guard let layer else {
            return []
        }
        var frames: [CGRect] = []
        func collect(_ parent: CALayer) {
            for child in parent.sublayers ?? [] {
                if child.contents != nil {
                    frames.append(layer.convert(child.bounds, from: child))
                }
                collect(child)
            }
        }
        collect(layer)
        return frames
    }

    /// An arrival while following fades in its own rows: the band runs from the old bottom padding to
    /// the new one, and the rows above it sit on the opaque base.
    private static func testWorkerChatArrivalFadesItsRowsIn() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        try expect(waitUntil { fixture.origin == 800 }, "a fresh feed should pin to the bottom, got \(fixture.origin)")
        try expect(fixture.documentView.layer?.mask == nil, "the first layout should not fade")

        fixture.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        fixture.grow(to: 1026)
        try expect(waitUntil { fixture.origin == 826 }, "the arrival should pin to the bottom, got \(fixture.origin)")
        let bands = fadeBands(on: fixture.documentView)
        try expect(bands.count == 1, "an arrival should add one fade band, got \(bands.count)")
        try expectBand(bands[0], from: 980, to: 1006)
        try expectFadeAdded(on: bands[0])
        try expect(maskBase(on: fixture.documentView)?.frame.height == 980, "the base should end where the band starts")
        try expect(fixture.documentView.layer?.mask?.frame.size == fixture.documentView.bounds.size, "the mask should span the document")
    }

    /// A second arrival during the first fade adds its own band below it. The first band keeps its fade,
    /// so its rows keep their timing and don't restart from transparent.
    private static func testWorkerChatArrivalDuringAFadeKeepsTheEarlierBand() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        try expect(waitUntil { fixture.origin == 800 }, "a fresh feed should pin to the bottom, got \(fixture.origin)")
        fixture.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        fixture.grow(to: 1026)
        try expect(waitUntil { fixture.origin == 826 }, "the first arrival should pin to the bottom, got \(fixture.origin)")
        guard let first = fadeBands(on: fixture.documentView).first, let firstFade = first.animation(forKey: WorkerChatMotion.enterKey) else {
            throw TestFailure("the first arrival should add a fade band")
        }
        // The clock is stopped, so the first fade is still in flight however long the run loop takes.
        pump(0.5)
        try expect(first.animation(forKey: WorkerChatMotion.enterKey) === firstFade, "a fade should hold while the clock is stopped")

        fixture.follower.noteLinesUpdate(revision: 2, trimCount: 0, appended: true)
        fixture.grow(to: 1052)
        try expect(waitUntil { fixture.origin == 852 }, "the second arrival should pin to the bottom, got \(fixture.origin)")
        try expect(fixture.follower.isFollowing, "an arrival during a fade should keep following")
        let bands = fadeBands(on: fixture.documentView)
        try expect(bands.count == 2, "an arrival during a fade should add a second band, got \(bands.count)")
        try expect(bands[0] === first && bands[0].animation(forKey: WorkerChatMotion.enterKey) === firstFade, "the first band should keep its fade")
        try expectBand(bands[1], from: 1006, to: 1032)
        try expectFadeAdded(on: bands[1])
        try expect(maskBase(on: fixture.documentView)?.frame.height == 980, "the base should still end where the first band starts")
    }

    /// A burst of lines in one update fades in as one band over all of them, and ends at the bottom.
    private static func testWorkerChatBurstFadesEveryNewRowInOneBand() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        try expect(waitUntil { fixture.origin == 800 }, "a fresh feed should pin to the bottom, got \(fixture.origin)")
        fixture.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        fixture.grow(to: 1156)
        try expect(waitUntil { fixture.origin == 956 }, "a burst should pin to the bottom, got \(fixture.origin)")
        let bands = fadeBands(on: fixture.documentView)
        try expect(bands.count == 1, "a burst in one update should add one band, got \(bands.count)")
        try expectBand(bands[0], from: 980, to: 1136)
        try expectFadeAdded(on: bands[0])
    }

    /// A fade that ends folds its band into the base, and the last one leaves the document unmasked. The
    /// end is driven by removing the fade, which runs the same completion as one that finishes on its own.
    private static func testWorkerChatFadesEndIntoTheBaseAndLeaveNoMask() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        try expect(waitUntil { fixture.origin == 800 }, "a fresh feed should pin to the bottom, got \(fixture.origin)")
        fixture.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        fixture.grow(to: 1026)
        try expect(waitUntil { fixture.origin == 826 }, "the first arrival should pin to the bottom, got \(fixture.origin)")
        fixture.follower.noteLinesUpdate(revision: 2, trimCount: 0, appended: true)
        fixture.grow(to: 1052)
        try expect(waitUntil { fixture.origin == 852 }, "the second arrival should pin to the bottom, got \(fixture.origin)")
        let bands = fadeBands(on: fixture.documentView)
        try expect(bands.count == 2, "two arrivals should leave two fade bands, got \(bands.count)")

        bands[0].removeAnimation(forKey: WorkerChatMotion.enterKey)
        try expect(waitUntil { bands[0].superlayer == nil }, "the first fade's end should drop its band")
        try expect((maskBase(on: fixture.documentView)?.frame.height ?? .infinity) >= 1006 - 0.5, "the base should cover the first band, got \(String(describing: maskBase(on: fixture.documentView)?.frame))")

        bands[1].removeAnimation(forKey: WorkerChatMotion.enterKey)
        try expect(waitUntil { fixture.documentView.layer?.mask == nil }, "the last fade's end should remove the mask")
    }

    /// Scrolled up, an arrival adds no fade. An update that isn't an append adds none either, since its
    /// rows don't sit below the old ones. The glide still runs for it.
    private static func testWorkerChatFadeNeedsFollowingAndAnAppend() throws {
        let scrolled = followerFixture(contentHeight: 1000)
        defer { scrolled.window.close() }
        try expect(waitUntil { scrolled.origin == 800 }, "a fresh feed should pin to the bottom, got \(scrolled.origin)")
        scrolled.scroll(to: 0)
        try expect(waitUntil { !scrolled.follower.isFollowing }, "scrolling to the top should stop following")
        scrolled.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        scrolled.grow(to: 1026)
        try expect(scrolled.documentView.layer?.mask == nil, "an arrival while scrolled up should not fade")

        let rewrapped = followerFixture(contentHeight: 1000)
        defer { rewrapped.window.close() }
        try expect(waitUntil { rewrapped.origin == 800 }, "a fresh feed should pin to the bottom, got \(rewrapped.origin)")
        rewrapped.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: false)
        rewrapped.grow(to: 1026)
        try expect(waitUntil { rewrapped.origin == 826 }, "the update should pin to the bottom, got \(rewrapped.origin)")
        try expect(rewrapped.documentView.layer?.mask == nil, "an update that isn't an append should not fade")
        try expectGlideAdded(on: rewrapped.documentView, startsBetween: 26, and: 26)
    }

    /// A trim or a viewport resize during a fade ends it at once, since the rows it sits over have moved.
    private static func testWorkerChatTrimAndResizeEndARunningFade() throws {
        let trimmed = followerFixture(contentHeight: 1000)
        defer { trimmed.window.close() }
        try expect(waitUntil { trimmed.origin == 800 }, "a fresh feed should pin to the bottom, got \(trimmed.origin)")
        trimmed.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        trimmed.grow(to: 1026)
        try expect(waitUntil { trimmed.origin == 826 }, "the arrival should pin to the bottom, got \(trimmed.origin)")
        try expect(trimmed.documentView.layer?.mask != nil, "the arrival should start a fade")
        trimmed.follower.noteLinesUpdate(revision: 2, trimCount: 1, appended: false)
        trimmed.grow(to: 1000)
        try expect(waitUntil { trimmed.origin == 800 }, "the trim should pin to the new bottom, got \(trimmed.origin)")
        try expect(trimmed.documentView.layer?.mask == nil, "a trim should end the running fade")

        let resized = followerFixture(contentHeight: 1000)
        defer { resized.window.close() }
        try expect(waitUntil { resized.origin == 800 }, "a fresh feed should pin to the bottom, got \(resized.origin)")
        resized.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        resized.grow(to: 1026)
        try expect(waitUntil { resized.origin == 826 }, "the arrival should pin to the bottom, got \(resized.origin)")
        try expect(resized.documentView.layer?.mask != nil, "the arrival should start a fade before the resize")
        resized.resize(height: 240)
        try expect(waitUntil { resized.origin == 786 }, "the resize should pin to the new bottom, got \(resized.origin)")
        try expect(resized.documentView.layer?.mask == nil, "a viewport resize should end the running fade")
    }

    /// The real feed, hosted: an arrival while following glides and fades in its rows, and the end of
    /// the fade removes the mask. The band lines up with the document's own rows.
    private static func testWorkerChatHostedArrivalGlidesAndFades() throws {
        let hosting = NSHostingView(rootView: wrappedFeed(count: 30, revision: 1, trimCount: 0, appended: false))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        try expect(waitUntil { descendant(NSScrollView.self, in: hosting) != nil }, "the worker chat feed should host a scroll view")
        guard let scrollView = descendant(NSScrollView.self, in: hosting), let documentView = scrollView.documentView else {
            throw TestFailure("the worker chat feed should host a scroll view with a document")
        }
        let viewport = { scrollView.contentView.bounds.height }
        holdMotion(scrollView, true)
        try expect(waitUntil { documentView.frame.height > viewport() }, "the first layout should fill the feed")
        try expect(waitUntil { abs(scrollView.contentView.bounds.origin.y - (documentView.frame.height - viewport())) < 1 }, "the first layout should pin to the bottom")
        try expect(documentView.layer?.mask == nil, "the first layout should not fade")

        let heightBefore = documentView.frame.height
        hosting.rootView = wrappedFeed(count: 31, revision: 2, trimCount: 0, appended: true)
        guard let arrival = waitForArrival(on: documentView) else {
            throw TestFailure("an arrival while following should fade its rows in and glide them")
        }
        pump(0.5)
        try expect(arrival.band.animation(forKey: WorkerChatMotion.enterKey) === arrival.fade, "the fade should hold while the clock is stopped")
        try expect(documentView.layer?.animation(forKey: WorkerChatMotion.glideKey) === arrival.glide, "the glide should hold while the clock is stopped")
        try expect(fadeBands(on: documentView).count == 1, "one arrival should add one fade band, got \(fadeBands(on: documentView).count)")
        try expectBand(arrival.band, from: heightBefore - WorkerChatMetrics.inset, to: documentView.frame.height - WorkerChatMetrics.inset)
        try expectFade(arrival.fade, on: arrival.band)
        try expectGlide(arrival.glide, on: documentView, startsBetween: 1, and: viewport())
        try expectRowsClearOfBand(arrival.band.frame, in: documentView.layer)

        holdMotion(scrollView, false)
        try expect(waitUntil { documentView.layer?.mask == nil }, "a fade that runs out should remove the mask")
    }

    /// No drawn row may straddle the band's edges, and at least one row must sit inside the band.
    private static func expectRowsClearOfBand(_ band: CGRect, in layer: CALayer?) throws {
        let isAboveOrInside = { (row: CGRect) in
            row.maxY <= band.minY + 0.5 || (row.minY >= band.minY - 0.5 && row.maxY <= band.maxY + 0.5)
        }
        let rows = contentFrames(in: layer)
        try expect(rows.contains { isAboveOrInside($0) && $0.minY >= band.minY - 0.5 }, "the new row should sit in the band")
        try expect(rows.allSatisfy(isAboveOrInside), "no row should straddle the band's edge, so the band covers exactly the new rows")
    }

    /// SwiftUI can grow the rows before the document. A band added then sits past the document's old edge, so the
    /// mask has to follow the document when it grows.
    private static func testWorkerChatRowsGrowingBeforeTheDocumentKeepTheMaskOverTheirFade() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        fixture.grow(to: 1026)
        fixture.follower.noteLinesUpdate(revision: 2, trimCount: 0, appended: true)
        fixture.follower.frame = NSRect(x: 0, y: WorkerChatMetrics.inset, width: 300, height: 1012)
        fixture.follower.sync(fixture.scrollView)
        try expect(fadeBands(on: fixture.documentView).count == 1, "the rows should fade in before the document grows")

        fixture.documentView.setFrameSize(NSSize(width: 300, height: 1052))
        fixture.follower.sync(fixture.scrollView)
        guard let mask = fixture.documentView.layer?.mask else {
            throw TestFailure("the fade should still be running once the document has grown")
        }
        try expect(mask.frame.height == 1052, "the mask should follow the document, got \(mask.frame.height)")
        try expectBand(fadeBands(on: fixture.documentView)[0], from: 1006, to: 1032)
    }

    /// An edit or a trim that keeps the rows' height moves nothing, so it ends a running fade on its own.
    private static func testWorkerChatNonAppendUpdateEndsAFadeWithoutAGeometryChange() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        fixture.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        fixture.grow(to: 1026)
        try expect(fixture.documentView.layer?.mask != nil, "the arrival should start a fade")

        fixture.follower.noteLinesUpdate(revision: 2, trimCount: 0, appended: false)
        try expect(fixture.documentView.layer?.mask == nil, "an edit that keeps the rows' height should end the fade")

        fixture.follower.noteLinesUpdate(revision: 3, trimCount: 0, appended: true)
        fixture.grow(to: 1052)
        try expect(fixture.documentView.layer?.mask != nil, "a second arrival should start a fade")
        fixture.follower.noteLinesUpdate(revision: 4, trimCount: 1, appended: false)
        try expect(fixture.documentView.layer?.mask == nil, "an equal-height trim should end the fade")
    }

    /// A short feed that gains rows past the viewport turns tall. The clip moves down while the rows move up in the
    /// document, so the glide covers both: the old rows start where they were on screen and glide to their place.
    private static func testWorkerChatCrossingTheViewportGlidesRowsFromTheirOldPlace() throws {
        let fixture = followerFixture(contentHeight: 200, rows: 100)
        defer { fixture.window.close() }
        try expect(fixture.origin == 0, "a short feed should sit at the top of the clip, got \(fixture.origin)")
        let rowsTopBefore = fixture.follower.frame.minY
        try expect(rowsTopBefore == 80, "100 pt of rows should sit on the bottom padding of a 200 pt feed, got \(rowsTopBefore)")

        fixture.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        fixture.show(rows: 200)
        try expect(fixture.origin == 40, "the crossing should pin to the new bottom, got \(fixture.origin)")
        try expectGlideAdded(on: fixture.documentView, startsBetween: 100, and: 100)
        guard let glide = fixture.documentView.layer?.animation(forKey: WorkerChatMotion.glideKey) as? CABasicAnimation,
              let start = (glide.fromValue as? NSNumber)?.doubleValue else {
            throw TestFailure("the crossing should add a glide with a start value")
        }
        let shownTop = fixture.follower.frame.minY - fixture.origin + CGFloat(start)
        try expect(abs(shownTop - rowsTopBefore) < 0.5, "the old rows should start where they were on screen, at \(rowsTopBefore), got \(shownTop)")
        try expectBand(fadeBands(on: fixture.documentView)[0], from: 120, to: 220)

        // Rows first: the rows reach their new place while the document is still short, then the document grows.
        // The first glide starts from the rows' move, and the second, uncommitted, starts from the first glide's start.
        let rowsFirst = followerFixture(contentHeight: 200, rows: 100)
        defer { rowsFirst.window.close() }
        rowsFirst.follower.noteLinesUpdate(revision: 1, trimCount: 0, appended: true)
        rowsFirst.follower.frame = NSRect(x: 0, y: WorkerChatMetrics.inset, width: 300, height: 200)
        rowsFirst.follower.sync(rowsFirst.scrollView)
        try expectBand(fadeBands(on: rowsFirst.documentView)[0], from: 120, to: 220)
        try expect(rowsFirst.origin == 0, "the short feed should not move the clip yet, got \(rowsFirst.origin)")

        rowsFirst.documentView.setFrameSize(NSSize(width: 300, height: 240))
        rowsFirst.follower.sync(rowsFirst.scrollView)
        try expect(rowsFirst.origin == 40, "the document's growth should pin to the new bottom, got \(rowsFirst.origin)")
        try expectBand(fadeBands(on: rowsFirst.documentView)[0], from: 120, to: 220)
        try expect(rowsFirst.documentView.layer?.mask?.frame.height == 240, "the mask should follow the document")
        try expectGlideAdded(on: rowsFirst.documentView, startsBetween: 100, and: 100)
    }

    /// The fade band and the glide that one arrival added to a hosted feed.
    private struct Arrival {
        let band: CALayer
        let fade: CABasicAnimation
        let glide: CABasicAnimation
    }

    /// Pumps until a hosted feed shows an arrival's fade and glide, for at most five seconds. Both are captured in
    /// the same check, so the arrival can be inspected even after its animations have run out.
    private static func waitForArrival(on view: NSView) -> Arrival? {
        var arrival: Arrival?
        let found = waitUntil {
            guard let band = fadeBands(on: view).last,
                  let fade = band.animation(forKey: WorkerChatMotion.enterKey) as? CABasicAnimation,
                  let glide = view.layer?.animation(forKey: WorkerChatMotion.glideKey) as? CABasicAnimation else {
                return false
            }
            arrival = Arrival(band: band, fade: fade, glide: glide)
            return true
        }
        return found ? arrival : nil
    }

    /// The real feed, hosted, while it fits the viewport: the document keeps its height, so an arrival shows
    /// only in the rows' frame. It fades the rows it added and lifts the rows into place.
    private static func testWorkerChatShortFeedArrivalFadesAndLifts() throws {
        let hosting = NSHostingView(rootView: wrappedFeed(count: 1, revision: 1, trimCount: 0, appended: true, wraps: false))
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        try expect(waitUntil { descendant(NSScrollView.self, in: hosting) != nil }, "the worker chat feed should host a scroll view")
        guard let scrollView = descendant(NSScrollView.self, in: hosting),
              let documentView = scrollView.documentView,
              let follower = descendant(WorkerChatBottomFollowerView.self, in: hosting) else {
            throw TestFailure("the worker chat feed should host a scroll view, a document and a follower")
        }
        let viewport = scrollView.contentView.bounds.height
        holdMotion(scrollView, true)
        try expect(waitUntil { follower.frame.height > 0 }, "the first layout should size the rows")
        try expect(documentView.frame.height == viewport, "one entry should leave the feed shorter than the viewport, got \(documentView.frame.height)")
        try expect(documentView.layer?.mask == nil, "the first layout should not fade")

        let documentHeight = documentView.frame.height
        let rowsBefore = follower.frame.height
        hosting.rootView = wrappedFeed(count: 2, revision: 2, trimCount: 0, appended: true, wraps: false)
        try expect(waitUntil { follower.frame.height > rowsBefore }, "the arrival should grow the rows")
        let added = follower.frame.height - rowsBefore
        try expect(documentView.frame.height == documentHeight, "a feed that still fits should keep its document height")
        guard let arrival = waitForArrival(on: documentView) else {
            throw TestFailure("an arrival in a short feed should fade its rows in and lift them into place")
        }
        pump(0.5)
        try expect(arrival.band.animation(forKey: WorkerChatMotion.enterKey) === arrival.fade, "the fade should hold while the clock is stopped")
        try expect(documentView.layer?.animation(forKey: WorkerChatMotion.glideKey) === arrival.glide, "the lift should hold while the clock is stopped")
        try expect(fadeBands(on: documentView).count == 1, "one arrival should add one fade band, got \(fadeBands(on: documentView).count)")
        try expectBand(arrival.band, from: documentHeight - WorkerChatMetrics.inset - added, to: documentHeight - WorkerChatMetrics.inset)
        try expectFade(arrival.fade, on: arrival.band)
        try expectGlide(arrival.glide, on: documentView, startsBetween: added, and: added)
        try expectRowsClearOfBand(arrival.band.frame, in: documentView.layer)

        holdMotion(scrollView, false)
        try expect(waitUntil { documentView.layer?.mask == nil }, "a fade that runs out should remove the mask")
    }

    /// A live scroll takes over from a glide at once, so the content isn't left displaced.
    private static func testWorkerChatLiveScrollCancelsGlide() throws {
        let fixture = followerFixture(contentHeight: 1000)
        defer { fixture.window.close() }
        try expect(waitUntil { fixture.origin == 800 }, "a fresh feed should pin to the bottom, got \(fixture.origin)")
        fixture.grow(to: 1026)
        try expect(waitUntil { hasGlide(fixture.documentView) }, "the arrival should start a glide")

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: fixture.scrollView)
        try expect(waitUntil { !hasGlide(fixture.documentView) }, "a live scroll should cancel the glide")
    }

    private static func settingsSheetModel(
        mutationClient: ServeMutationSending,
        modelClient: ServeModelSuggesting? = nil,
        effortClient: ServeReasoningEffortSuggesting? = nil,
        dismiss: @escaping () -> Void = {}
    ) -> SettingsSheetModel {
        SettingsSheetModel(
            presentation: SettingsSheetPresentation(
                mutationClient: mutationClient,
                modelClient: modelClient,
                effortClient: effortClient
            ),
            dismiss: dismiss
        )
    }

    private static func sessionCoordinator(
        client: ServeMutationSending,
        failures: Counter,
        switches: Counter? = nil
    ) -> SessionCoordinator {
        SessionCoordinator(
            store: RuntimeStore(sourceLabel: "test"),
            mutationClient: client,
            dependencies: SessionCoordinator.Dependencies(
                switchTerminal: { _, completion in
                    switches?.value += 1
                    completion?(true)
                },
                showMutationFailure: { _, _ in failures.value += 1 },
                clearTerminalMessage: {},
                showTerminalEndedMessage: {},
                render: {}
            )
        )
    }

    private static func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    private static func trackerShowsSkeleton(for observedLabel: String) -> Bool {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.apply(.serveUnavailable(observedLabel))
        return isServeStartingMessage(snapshot.serviceStateMessage)
    }

    private static func renderedColor(_ rows: [TrackerRenderedSession], id: String) throws -> NSColor {
        guard let row = rows.first(where: { $0.session.id == id }) else {
            throw TestFailure("missing rendered row \(id)")
        }
        return row.groupColor
    }

    private static func keyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try keyEvent(characters, keyCode: keyCode, modifierFlags: [])
    }

    private static func keyEvent(_ characters: String, keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw TestFailure("could not create \(characters) key event")
        }
        return event
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(message)
        }
    }

    private final class StubMutationClient: ServeMutationSending {
        let result: Result<ServeMutationAck, Error>
        private let deferCompletions: Bool
        private(set) var sentRequests: [ServeMutationRequest] = []
        private var pendingCompletions: [() -> Void] = []

        init(result: Result<ServeMutationAck, Error>, deferCompletions: Bool = false) {
            self.result = result
            self.deferCompletions = deferCompletions
        }

        func send(_ request: ServeMutationRequest, completion: @escaping (Result<ServeMutationAck, Error>) -> Void) {
            sentRequests.append(request)
            let result = self.result
            let fire: () -> Void = { completion(result) }
            guard deferCompletions else {
                fire()
                return
            }
            pendingCompletions.append(fire)
        }

        /// Fires one deferred completion by the index of the request it
        /// belongs to (0-based, matching `sentRequests`) — mirrors
        /// StubModelClient's own deferred-completion helper.
        func fireCompletion(forRequestAt index: Int) {
            guard pendingCompletions.indices.contains(index) else {
                return
            }
            let fire = pendingCompletions[index]
            pendingCompletions[index] = { () -> Void in }
            fire()
        }
    }

    private struct StubMutationError: Error {}

    private final class StubModelClient: ServeModelSuggesting {
        private let models: [String: [SessionModelOption]]
        private let defaults: [String: String]
        private let failing: Bool
        private let deferCompletions: Bool
        /// When set, overrides the per-agent `models` lookup with one entry
        /// per call, in call order, regardless of agent — lets a test give
        /// two calls for the *same* agent distinguishable responses, which is
        /// what proves which of two racing completions actually won.
        private let sequencedModels: [[SessionModelOption]]?
        private(set) var requests: [(agent: String, role: String, refresh: Bool)] = []
        private var pendingCompletions: [() -> Void] = []

        init(
            models: [String: [SessionModelOption]] = [:],
            defaults: [String: String] = [:],
            failing: Bool = false,
            deferCompletions: Bool = false,
            sequencedModels: [[SessionModelOption]]? = nil
        ) {
            self.models = models
            self.defaults = defaults
            self.failing = failing
            self.deferCompletions = deferCompletions
            self.sequencedModels = sequencedModels
        }

        func suggestModels(
            agent: String,
            role: String,
            refresh: Bool,
            completion: @escaping (Result<ModelSuggestionResponse, Error>) -> Void
        ) {
            let requestIndex = requests.count
            requests.append((agent: agent, role: role, refresh: refresh))
            let resolvedModels = sequencedModels.flatMap { sequence in
                sequence.indices.contains(requestIndex) ? sequence[requestIndex] : nil
            } ?? models[agent] ?? []
            let failing = self.failing
            let defaultModel = defaults[agent] ?? ""
            let fire: () -> Void = {
                if failing {
                    completion(.failure(StubMutationError()))
                    return
                }
                completion(.success(ModelSuggestionResponse(models: resolvedModels, defaultModel: defaultModel)))
            }
            guard deferCompletions else {
                fire()
                return
            }
            pendingCompletions.append(fire)
        }

        /// Fires one deferred completion by the index of the request it
        /// belongs to (0-based, matching `requests`), letting a test choose
        /// an arrival order that differs from call order. A no-op past the
        /// first fire, so firing the same index twice can't double-invoke it.
        func fireCompletion(forRequestAt index: Int) {
            guard pendingCompletions.indices.contains(index) else {
                return
            }
            let fire = pendingCompletions[index]
            pendingCompletions[index] = { () -> Void in }
            fire()
        }
    }

    private final class StubReasoningEffortClient: ServeReasoningEffortSuggesting {
        private let efforts: [String: [String]]
        private let defaults: [String: String]
        private(set) var requests: [(agent: String, role: String, model: String)] = []

        init(efforts: [String: [String]] = [:], defaults: [String: String] = [:]) {
            self.efforts = efforts
            self.defaults = defaults
        }

        func suggestReasoningEfforts(
            agent: String,
            role: String,
            model: String,
            completion: @escaping (Result<ReasoningEffortSuggestionResponse, Error>) -> Void
        ) {
            requests.append((agent: agent, role: role, model: model))
            let key = model.isEmpty ? agent : model
            completion(.success(ReasoningEffortSuggestionResponse(
                efforts: efforts[key] ?? efforts[agent] ?? [],
                defaultEffort: defaults[key] ?? defaults[agent] ?? ""
            )))
        }
    }

    private final class Counter {
        var value = 0
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
