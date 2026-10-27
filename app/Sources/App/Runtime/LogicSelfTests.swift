#if DEBUG
import AppKit
import Combine
import Darwin
import Foundation
import QuestmasterCore
import SwiftUI

@MainActor
enum LogicSelfTests {
    private static let cases: [(name: String, body: @MainActor () throws -> Void)] = [
        ("testAppBackendResolverFeedsLaunchConfiguration", testAppBackendResolverFeedsLaunchConfiguration),
        ("testLaunchFlagMappingTable", testLaunchFlagMappingTable),
        ("testDaemonEnsureUsesRespawnPolicy", testDaemonEnsureUsesRespawnPolicy),
        ("testDevBackendBeatsGlobalPathInSourceCheckout", testDevBackendBeatsGlobalPathInSourceCheckout),
        ("testPackagedBundleBeatsDevAndGlobalBackends", testPackagedBundleBeatsDevAndGlobalBackends),
        ("testAppChildProcessEnvironmentAppliesBackendAfterNormalizedPath", testAppChildProcessEnvironmentAppliesBackendAfterNormalizedPath),
        ("testDaemonRecordFeedsTerminalEnvironment", testDaemonRecordFeedsTerminalEnvironment),
        ("testTmuxStartupScriptScopesAppBackendEnvironmentToSession", testTmuxStartupScriptScopesAppBackendEnvironmentToSession),
        ("testNavigationTogglesFocusShownRegionAndHideToTerminal", testNavigationTogglesFocusShownRegionAndHideToTerminal),
        ("testDirectionalRegionFocusMapping", testDirectionalRegionFocusMapping),
        ("testKeymapErgonomicsBindings", testKeymapErgonomicsBindings),
        ("testArtifactNavigationPolicy", testArtifactNavigationPolicy),
        ("testLocalMarkdownImageURLFiltering", testLocalMarkdownImageURLFiltering),
        ("testTrackerSkeletonMatchesServeStartupMessages", testTrackerSkeletonMatchesServeStartupMessages),
        ("testShellRowsLeaveTheRepoGroupsForTheirOwnSection", testShellRowsLeaveTheRepoGroupsForTheirOwnSection),
        ("testAnAttachedShellsPanelBarFollowsItsOwnColour", testAnAttachedShellsPanelBarFollowsItsOwnColour),
        ("testWorkerSummaryShowsOneCirclePerWorkerAndCountsTheRest", testWorkerSummaryShowsOneCirclePerWorkerAndCountsTheRest),
        ("testTrackerPlatesKeepTheDesignsProportions", testTrackerPlatesKeepTheDesignsProportions),
        ("testTheAttachedDotSitsBesideTheDiscWholeAndOnTheRightPlate", testTheAttachedDotSitsBesideTheDiscWholeAndOnTheRightPlate),
        ("testTrackerBandPrecedence", testTrackerBandPrecedence),
        ("testPortraitStatusFollowsTheFilterValues", testPortraitStatusFollowsTheFilterValues),
        ("testPlateAndCircleStatusDrawsOnlyForActiveStatuses", testPlateAndCircleStatusDrawsOnlyForActiveStatuses),
        ("testPlateTimeColumnFitsRunsPastNinetyNineHours", testPlateTimeColumnFitsRunsPastNinetyNineHours),
        ("testCastFillAnimatesOnlyWhileCastingInAWindow", testCastFillAnimatesOnlyWhileCastingInAWindow),
        ("testElapsedTimeShowsOnlyWhileWorkingAndIsLiveOnlyWhenCounting", testElapsedTimeShowsOnlyWhileWorkingAndIsLiveOnlyWhenCounting),
        ("testDurationClockHasOneTimerWhateverTheSubscribers", testDurationClockHasOneTimerWhateverTheSubscribers),
        ("testOnlyLiveElapsedTimesSubscribeToTheDurationClock", testOnlyLiveElapsedTimesSubscribeToTheDurationClock),
        ("testSelectedSessionPanelNamesTheAttachedSessionsProject", testSelectedSessionPanelNamesTheAttachedSessionsProject),
        ("testSelectedSessionPanelFrameKeepsItsRoundedCorners", testSelectedSessionPanelFrameKeepsItsRoundedCorners),
        ("testPortraitRingAnimatesByItsMode", testPortraitRingAnimatesByItsMode),
        ("testStartupTmuxSessionChoice", testStartupTmuxSessionChoice),
        ("testDockContentRoutingRequiresASession", testDockContentRoutingRequiresASession),
        ("testArtifactDockCommandSwitchesFromWorkerChat", testArtifactDockCommandSwitchesFromWorkerChat),
        ("testModalsPresentInsideTheWindowNotAsSystemSheets", testModalsPresentInsideTheWindowNotAsSystemSheets),
        ("testModalStackClosesTheTopModalFirstAndRestoresFocus", testModalStackClosesTheTopModalFirstAndRestoresFocus),
        ("testShellFocusRequestsWaitForTheModals", testShellFocusRequestsWaitForTheModals),
        ("testSummonLeavesFocusOnTheNewTerminal", testSummonLeavesFocusOnTheNewTerminal),
        ("testClosingAChildRefocusesTheModalItUncovers", testClosingAChildRefocusesTheModalItUncovers),
        ("testDockFrameFollowsFocusAndModals", testDockFrameFollowsFocusAndModals),
        ("testRestoringFocusAfterTheLastModalKeepsAFieldsCaret", testRestoringFocusAfterTheLastModalKeepsAFieldsCaret),
        ("testClosingAChildKeepsTheUncoveredFieldsSelection", testClosingAChildKeepsTheUncoveredFieldsSelection),
        ("testQuestLogOpensScrolledToTheKeptSelection", testQuestLogOpensScrolledToTheKeptSelection),
        ("testQuestLogOpensWithoutRedrawingTheParchment", testQuestLogOpensWithoutRedrawingTheParchment),
        ("testQuestLogPageScrollsWithTheWheel", testQuestLogPageScrollsWithTheWheel),
        ("testTheTitleFieldsTextStaysPutWhenTheClassSegmentChanges", testTheTitleFieldsTextStaysPutWhenTheClassSegmentChanges),
        ("testEditSessionKeepsItsTitleTextStillWhenControlECyclesTheClass", testEditSessionKeepsItsTitleTextStillWhenControlECyclesTheClass),
        ("testFilterBarTextSitsOnOneBaselineRestingAndFocused", testFilterBarTextSitsOnOneBaselineRestingAndFocused),
        ("testTextFieldsFitTheirWholeLine", testTextFieldsFitTheirWholeLine),
        ("testRenderedSpacingStaysOnTheScale", testRenderedSpacingStaysOnTheScale),
        ("testChromeShadowsReachPastTheirClips", testChromeShadowsReachPastTheirClips),
        ("testShellRowsKeepTheMocksGeometry", testShellRowsKeepTheMocksGeometry),
        ("testTheShellSectionIsPinnedToTheTrackersBottom", testTheShellSectionIsPinnedToTheTrackersBottom),
        ("testTheShellSectionScrollsInsideItselfPastItsMaxHeight", testTheShellSectionScrollsInsideItselfPastItsMaxHeight),
        ("testFilterFieldFocusFollowsTheFirstResponder", testFilterFieldFocusFollowsTheFirstResponder),
        ("testDockKeepsItsStateAcrossSessionSwitches", testDockKeepsItsStateAcrossSessionSwitches),
        ("testNewArtifactsOpenFromBehindTheWorkerChat", testNewArtifactsOpenFromBehindTheWorkerChat),
        ("testDockPanePublishesModeChanges", testDockPanePublishesModeChanges),
        ("testVersionControlDockKeysMoveOpenCopyAndRefresh", testVersionControlDockKeysMoveOpenCopyAndRefresh),
        ("testRefreshSpinnerIsTheTrackersSpinnerAndTurnsOnlyInAWindow", testRefreshSpinnerIsTheTrackersSpinnerAndTurnsOnlyInAWindow),
        ("testVersionControlTitleBarShowsTheSpinnerWhileTheStoreRefreshes", testVersionControlTitleBarShowsTheSpinnerWhileTheStoreRefreshes),
        ("testDockColumnLaysOutItsPanels", testDockColumnLaysOutItsPanels),
        ("testOnlyTheFocusedDockPanelHasTheKeys", testOnlyTheFocusedDockPanelHasTheKeys),
        ("testDockPanelsTransitionOnceAndSkipItWithReducedMotion", testDockPanelsTransitionOnceAndSkipItWithReducedMotion),
        ("testCommandKeysReachTheirActionsWhileTheTerminalConsumesKeyEquivalents", testCommandKeysReachTheirActionsWhileTheTerminalConsumesKeyEquivalents),
        ("testDockSelectionPublishesImmediately", testDockSelectionPublishesImmediately),
        ("testGChordShortcutDecidesFromCharacterIgnoringCapsLock", testGChordShortcutDecidesFromCharacterIgnoringCapsLock),
        ("testArtifactListGChordJumpsToEdgesAndForcesRescroll", testArtifactListGChordJumpsToEdgesAndForcesRescroll),
        ("testListGChordPendingGResetsOnGAndOnInterveningKey", testListGChordPendingGResetsOnGAndOnInterveningKey),
        ("testArtifactDockCopiesSelectedArtifactPathWithY", testArtifactDockCopiesSelectedArtifactPathWithY),
        ("testArtifactDockCopiesMultipleSelectedArtifactPathsWithY", testArtifactDockCopiesMultipleSelectedArtifactPathsWithY),
        ("testArtifactDockDeletesSelectedArtifactsWithD", testArtifactDockDeletesSelectedArtifactsWithD),
        ("testArtifactViewerCopiesAndRefreshesWithKeys", testArtifactViewerCopiesAndRefreshesWithKeys),
        ("testArtifactViewerBackKeysReturnToList", testArtifactViewerBackKeysReturnToList),
        ("testSessionCoordinatorRunsSuccessCallbackOnlyAfterAck", testSessionCoordinatorRunsSuccessCallbackOnlyAfterAck),
        ("testArtifactDockAllFiltersUseVisibleList", testArtifactDockAllFiltersUseVisibleList),
        ("testDeferredDeleteConfirmationRetainsExecutor", testDeferredDeleteConfirmationRetainsExecutor),
        ("testNewSessionArrowKeysNavigatePathSuggestions", testNewSessionArrowKeysNavigatePathSuggestions),
        ("testNewSessionResolvesModelsPerAgent", testNewSessionResolvesModelsPerAgent),
        ("testNewSessionKeepsDefaultModelWhenResolveFails", testNewSessionKeepsDefaultModelWhenResolveFails),
        ("testNewSessionDiscardsStaleModelResponseArrivingAfterANewerOne", testNewSessionDiscardsStaleModelResponseArrivingAfterANewerOne),
        ("testNewSessionResolvesReasoningEffortsPerAgentAndModel", testNewSessionResolvesReasoningEffortsPerAgentAndModel),
        ("testNewSessionKeepsDefaultReasoningEffortWhenResolveFails", testNewSessionKeepsDefaultReasoningEffortWhenResolveFails),
        ("testNewSessionEffortKeysCycleWhereAnECannotBeTyped", testNewSessionEffortKeysCycleWhereAnECannotBeTyped),
        ("testNewSessionClassCyclesInTheTitleAndSummonSendsAChosenOne", testNewSessionClassCyclesInTheTitleAndSummonSendsAChosenOne),
        ("testEveryPortraitIsBundledUnderItsOwnName", testEveryPortraitIsBundledUnderItsOwnName),
        ("testNewSessionTabTakesTheHighlightedModelThenMovesOn", testNewSessionTabTakesTheHighlightedModelThenMovesOn),
        ("testNewSessionEscapePutsADropdownAwayBeforeClosing", testNewSessionEscapePutsADropdownAwayBeforeClosing),
        ("testNewQuestTypedPathSubmitsAPathOnlyProject", testNewQuestTypedPathSubmitsAPathOnlyProject),
        ("testNewQuestReturnKeepsATypedPathUnlessARowWasChosen", testNewQuestReturnKeepsATypedPathUnlessARowWasChosen),
        ("testNewQuestLeavingAndReturningToTheProjectFieldEndsItsSearch", testNewQuestLeavingAndReturningToTheProjectFieldEndsItsSearch),
        ("testNewQuestEscapeClosesWhileSubmitting", testNewQuestEscapeClosesWhileSubmitting),
        ("testNewSessionControlRRefreshesModelsFromTheModelField", testNewSessionControlRRefreshesModelsFromTheModelField),
        ("testConnectWithRetryRetriesUntilConnectSucceeds", testConnectWithRetryRetriesUntilConnectSucceeds),
        ("testConnectWithRetryGivesUpAfterExhaustingTheSchedule", testConnectWithRetryGivesUpAfterExhaustingTheSchedule),
        ("testOneShotServeClientsRejectIncompatibleEnvelopes", testOneShotServeClientsRejectIncompatibleEnvelopes),
        ("testServeStreamReconnectsAfterProtocolMismatch", testServeStreamReconnectsAfterProtocolMismatch),
        ("testSettingsCyclingAFieldSendsItsRoleDefaultImmediately", testSettingsCyclingAFieldSendsItsRoleDefaultImmediately),
        ("testSettingsCloseDoesNotWaitForInFlightSaves", testSettingsCloseDoesNotWaitForInFlightSaves),
        ("testSettingsFailedSaveSurfacesErrorMessage", testSettingsFailedSaveSurfacesErrorMessage),
        ("testSettingsResendsAnEditMadeWhileAPreviousSaveIsInFlight", testSettingsResendsAnEditMadeWhileAPreviousSaveIsInFlight),
        ("testActionBarFooterHeightIsIntegral", testActionBarFooterHeightIsIntegral),
        ("testActionBarSlotsCentreInsideFooter", testActionBarSlotsCentreInsideFooter),
        ("testActionBarHitTestUsesSuperviewCoordinates", testActionBarHitTestUsesSuperviewCoordinates),
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
        ("testGhosttyFamilyWithoutSemiboldOrItalicFallsBackToSystemFace", testGhosttyFamilyWithoutSemiboldOrItalicFallsBackToSystemFace),
        ("testMenloSemiboldIsNotSubstitutedWithBold", testMenloSemiboldIsNotSubstitutedWithBold),
        ("testAppFontsUseGhosttyFamilyWhenItHasTheFace", testAppFontsUseGhosttyFamilyWhenItHasTheFace),
        ("testMarkdownFamilyNeedsEveryFaceItsThemesUse", testMarkdownFamilyNeedsEveryFaceItsThemesUse),
    ]

    private static let caseTimeoutSeconds: TimeInterval = 120

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
            // A blocked call (process, socket, window server) never returns to the loop, so a
            // watchdog off the main thread names the case and fails instead of hanging CI.
            let watchdog = DispatchWorkItem {
                fputs("Questmaster self-tests failed: \(testCase.name): no result after \(Int(caseTimeoutSeconds)) seconds\n", stderr)
                exit(1)
            }
            let started = Date()
            print("RUN \(testCase.name)")
            fflush(stdout)
            DispatchQueue.global().asyncAfter(deadline: .now() + caseTimeoutSeconds, execute: watchdog)
            do {
                try testCase.body()
                watchdog.cancel()
                print(String(format: "PASS %@ %.2fs", testCase.name, Date().timeIntervalSince(started)))
                fflush(stdout)
                passed += 1
            } catch {
                watchdog.cancel()
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
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            bundle: fixture.bundle
        )
        try expect(config.backend.stateRoot == fixture.stateRoot.path, "resolver should pin state root")
        try expect(config.backend.executablePath == fixture.qm.path, "resolver should select bundled qm")
        try expect(config.backend.source == .bundled, "resolver source should be bundled")
        try expect(config.startDaemon && config.daemonSocketOverride == nil, "bundle should ensure its daemon")
        try expect(config.backend.command("start")?.arguments == ["daemon", "start"], "bundle should use daemon start")
        try expect(config.backend.command("start")?.workingDirectory == fixture.environment["HOME"], "bundle command should not depend on the launching cwd")
    }

    private static func testLaunchFlagMappingTable() throws {
        let fixture = try appBackendFixture()
        func load(_ arguments: [String], _ environment: [String: String]? = nil) -> LaunchConfiguration {
            LaunchConfiguration.load(arguments: arguments, environment: environment ?? fixture.environment,
                                     workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        }
        try expect(!load(["--no-daemon-start"]).startDaemon, "no-daemon-start should connect only")
        let socket = fixture.root.appendingPathComponent("custom.sock").path
        try expect(!load(["--daemon-socket", socket]).startDaemon, "daemon-socket should bypass Ensure")
        try expect(load(["--daemon-socket", socket]).daemonSocketOverride == socket, "socket flag should be retained")
        var env = fixture.environment
        env["QUESTMASTER_DAEMON_SOCKET"] = socket
        try expect(load([], env).daemonSocketOverride == socket, "socket environment should connect only")
        let override = load(["--qm-bin", fixture.qm.path, "--state-root", fixture.root.path])
        try expect(override.backend.source == .override && override.backend.stateRoot == fixture.root.path, "qm-bin and state-root should apply")
        try expect(load(["--no-serve", "--serve-socket", socket]).startDaemon, "removed flags should have no effect")
        try expect(load(["--no-serve-launch", "--external-serve", "--serve-executable", fixture.qm.path]).startDaemon,
                   "removed launch flags should have no effect")
        env.removeValue(forKey: "QUESTMASTER_DAEMON_SOCKET")
        env["QUESTMASTER_QM"] = fixture.qm.path
        env["QUESTMASTER_SERVE_SOCKET"] = socket
        try expect(load([], env).startDaemon, "removed environment overrides should have no effect")
    }

    private static func testDaemonEnsureUsesRespawnPolicy() throws {
        let fixture = try appBackendFixture()
        let marker = fixture.root.appendingPathComponent("attempts")
        try writeExecutable("#!/bin/sh\nprintf x >> '\(marker.path)'\nexit 1\n", to: fixture.qm)
        let start = LaunchConfiguration.load(environment: fixture.environment,
                                             workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        let now = Date(timeIntervalSince1970: 1_000)
        let connection = DaemonConnection(config: start, now: { now })
        for _ in 0..<2 {
            var failed = false
            do { _ = try connection.record() } catch { failed = true }
            try expect(failed, "broken daemon command should fail")
        }
        let attempts = try String(contentsOf: marker, encoding: .utf8)
        try expect(attempts == "xxxx", "Ensure should make one initial attempt and three delayed retries, then cool down")
        do { _ = try connection.record(userInitiated: true) } catch { /* Expected. */ }
        let afterUserAction = try String(contentsOf: marker, encoding: .utf8)
        try expect(afterUserAction == "xxxxxxxx", "user request should retry even during the cool-down")

        let connectOnly = LaunchConfiguration.load(arguments: ["--no-daemon-start"], environment: fixture.environment,
                                                    workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        do { _ = try DaemonConnection(config: connectOnly).record() } catch { /* Expected. */ }
        let afterStatus = try String(contentsOf: marker, encoding: .utf8)
        try expect(afterStatus == "xxxxxxxxx", "connect-only should run status once and never Ensure")
    }

    /// Shells leave the repo groups for a section under every plate, in snapshot order, and the order the cursor and the
    /// Cmd+N numbers walk ends with them. A repo left with only shells draws nothing; the panel still names an attached
    /// shell's repo.
    private static func testShellRowsLeaveTheRepoGroupsForTheirOwnSection() throws {
        let master = TrackerSession(id: "master", title: "Master", repoName: "Repo", agent: "codex", role: "master")
        let worker = TrackerSession(id: "worker", title: "Worker", repoName: "Repo", agent: "codex", role: "worker", parentID: "master")
        let first = TrackerSession(id: "shell-first", title: "Shell", repoName: "", agent: "")
        let second = TrackerSession(id: "shell-second", title: "Shell", repoName: "Repo", repoColor: "green", displayColor: "magenta", agent: "")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "ungrouped", name: "ungrouped", sessions: [first]),
            TrackerRepo(id: "repo", name: "Repo", color: "green", sessions: [master, second, worker]),
        ])

        let tracker = TrackerRenderer.tracker(snapshot)
        try expect(tracker.repos.map(\.repo.name) == ["Repo"], "a repo of only shells should draw no group, got \(tracker.repos.map(\.repo.name))")
        let plateIDs = tracker.repos.flatMap { repo in repo.groups.flatMap { [$0.root.session.id] + $0.workers.map(\.session.id) } }
        try expect(plateIDs == ["master", "worker"], "the repo should keep only its master and worker, got \(plateIDs)")
        try expect(tracker.shells.map(\.rendered.session.id) == ["shell-first", "shell-second"], "the shells should keep the snapshot's order")
        let rowIDs = TrackerRenderer.flatSessions(in: tracker).map(\.id)
        try expect(rowIDs == ["master", "worker", "shell-first", "shell-second"], "the cursor and the numbers should walk the plates, then the shells, got \(rowIDs)")

        let panel = SelectedSessionPanelContent.make(currentTerminalSessionID: "shell-second", tracker: tracker)
        try expect(panel.id == "shell-second" && panel.projectName == "Repo", "the panel should name an attached shell's repo, got \(panel.id) / \(panel.projectName)")
    }

    /// An attached shell's panel bar is its own display colour when it has one; without, the shell grey, never its repo's
    /// colour (a shell keeps the accent it always had).
    private static func testAnAttachedShellsPanelBarFollowsItsOwnColour() throws {
        let own = TrackerSession(id: "shell-own", title: "Shell", repoName: "Repo", repoColor: "green", displayColor: "magenta", agent: "")
        let inheriting = TrackerSession(id: "shell-inheriting", title: "Shell", repoName: "Repo", repoColor: "green", agent: "")
        let none = TrackerSession(id: "shell-none", title: "Shell", repoName: "Repo", repoColor: "green", displayColor: "none", agent: "")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [TrackerRepo(id: "repo", name: "Repo", color: "green", sessions: [own, inheriting, none])])
        let tracker = TrackerRenderer.tracker(snapshot)

        func barColor(attached id: String) -> NSColor {
            SelectedSessionPanelContent.make(currentTerminalSessionID: id, tracker: tracker).projectColor
        }
        guard let magenta = AppPalette.displayColor("magenta") else {
            throw TestFailure("magenta should be a display colour")
        }
        try expect(barColor(attached: "shell-own").isEqual(TrackerNameplateColor.barLightness(magenta)), "an attached shell with its own colour should show it on the panel's bar")
        let grey = TrackerNameplateColor.barLightness(AppPalette.muted)
        try expect(barColor(attached: "shell-inheriting").isEqual(grey), "an attached shell with no colour should show the shell grey, not its repo's green")
        try expect(barColor(attached: "shell-none").isEqual(grey), "the none colour is no colour")
        try expect(TrackerRenderer.shellTint(for: own)?.isEqual(magenta) == true, "the row's title takes the same own colour")
        try expect(TrackerRenderer.shellTint(for: inheriting) == nil && TrackerRenderer.shellTint(for: none) == nil, "no own colour tints nothing")
    }

    /// The ring in Core Animation: a steady ring is still, a spinning one turns, a filling one sweeps to full and then
    /// pulses, an ended cast flashes, a new learned duration only re-targets the fill; reduce motion keeps the fill but
    /// stills the rest, and nothing animates outside a window, nor keeps exiting once out of one.
    private static func testPortraitRingAnimatesByItsMode() throws {
        let window = HeadlessWindow(size: CGSize(width: 80, height: 80))
        let geometry = TrackerPlateDesign.collapsedCircleStatus
        let bash = TrackerCast(tool: "Bash", startedAt: Date().addingTimeInterval(-2), typicalMS: 6000)

        let outside = TrackerPortraitStatusNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        outside.configure(geometry: geometry, color: AppPalette.accent, ring: .filling(bash), reduceMotion: false)
        try expect(outside.fillAnimation == nil && outside.pulseAnimation == nil, "a ring outside a window should not animate")

        let status = TrackerPortraitStatusNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView = status
        status.configure(geometry: geometry, color: AppPalette.trackerBlocked, ring: .steady, reduceMotion: false)
        try expect(status.fillAnimation == nil && status.spinAnimation == nil && status.pulseAnimation == nil, "a steady ring should not move")

        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        guard let spin = status.spinAnimation else { throw TestFailure("working with no tool should spin the ring") }
        try expect(spin.duration == WorkingSpinner.period && spin.repeatCount == .infinity, "the spinner should orbit once every 1.2s, for good")

        status.configure(geometry: geometry, color: AppPalette.accent, ring: .filling(bash), reduceMotion: false)
        guard let fill = status.fillAnimation, let pulse = status.pulseAnimation else { throw TestFailure("a cast with a learned duration should fill the ring, then pulse") }
        try expect(abs(fill.duration - 4) < 0.1 && (fill.toValue as? CGFloat) == 1, "2s into a 6s tool the ring should fill to full in 4s, got \(fill.duration)")
        try expect(abs(pulse.beginTime - CACurrentMediaTime() - 4) < 0.2, "the pulse should start when the ring is full")
        try expect(status.spinAnimation == nil, "a filling ring should not spin")

        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        try expect(status.flashAnimation != nil && status.spinAnimation != nil, "an ended cast should flash, then spin while still working")
        status.configure(geometry: geometry, color: AppPalette.accent, ring: .steady, reduceMotion: false)
        try expect(status.flashAnimation == nil, "a ring with no cast to end should not flash")

        let relearned = TrackerCast(tool: bash.tool, startedAt: bash.startedAt, typicalMS: 9000)
        status.configure(geometry: geometry, color: AppPalette.accent, ring: .filling(relearned), reduceMotion: false)
        try expect(status.flashAnimation == nil && status.fillAnimation != nil, "a new typical for the same call should re-target the fill, not flash")
        let unlearned = TrackerCast(tool: bash.tool, startedAt: bash.startedAt, typicalMS: 0)
        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(unlearned), reduceMotion: false)
        status.configure(geometry: geometry, color: AppPalette.accent, ring: .filling(bash), reduceMotion: false)
        try expect(status.flashAnimation == nil && status.fillAnimation != nil, "a duration learned mid-call should start the fill, not flash")

        status.configure(geometry: geometry, color: AppPalette.accent, ring: .filling(bash), reduceMotion: true)
        try expect(status.fillAnimation != nil && status.pulseAnimation == nil, "reduce motion should keep the fill, with no pulse")
        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: true)
        try expect(status.spinAnimation == nil && status.flashAnimation == nil, "reduce motion should hold a full ring, with no flash")
        status.configure(geometry: geometry, color: AppPalette.trackerDone, ring: .none, finishColor: AppPalette.trackerDone, reduceMotion: true)
        try expect((status.exitAnimation as? CABasicAnimation)?.keyPath == "opacity", "under reduce motion the exit should only fade")

        // Leaving work: the ring completes, flashes and fades into no ring; into a steady status it crossfades.
        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        try expect(status.exitAnimation == nil, "a working ring should not be exiting")
        status.configure(geometry: geometry, color: AppPalette.trackerDone, ring: .none, finishColor: AppPalette.trackerDone, reduceMotion: false)
        guard let exit = status.exitAnimation as? CAKeyframeAnimation else { throw TestFailure("a ring that stops working should play its exit") }
        let total = TrackerPortraitStatusNSView.exitSweep + TrackerCastPhase.flashDuration + TrackerPortraitStatusNSView.exitFade
        try expect(abs(exit.duration - total) < 0.01, "the exit should sweep, flash and fade over \(total)s, got \(exit.duration)")
        try expect(status.spinAnimation == nil, "the spinner should stop as the ring exits")
        status.configure(geometry: geometry, color: AppPalette.trackerBlocked, ring: .steady, reduceMotion: false)
        try expect(status.exitAnimation == nil, "a ring with nothing to exit from should not play the exit")
        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        status.configure(geometry: geometry, color: AppPalette.trackerBlocked, ring: .steady, reduceMotion: false)
        try expect(status.layer?.animation(forKey: kCATransition) != nil, "working into a steady status should crossfade")

        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        status.configure(geometry: geometry, color: AppPalette.trackerDone, ring: .none, finishColor: AppPalette.trackerDone, reduceMotion: false)
        try expect(status.exitAnimation != nil, "the exit should be playing")
        window.contentView = nil
        try expect(status.exitAnimation == nil, "a ring leaving its window should stop its exit")
    }

    private static func testTrackerBandPrecedence() throws {
        try expect(TrackerGlowNSView.bandOpacity == 0.6, "the band should hold 0.6")

        let window = HeadlessWindow(size: CGSize(width: 80, height: 80))
        let held = TrackerGlowNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        window.contentView = held
        held.configure(path: CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40), transform: nil), color: AppPalette.bright)
        try expect(held.layer?.animationKeys()?.isEmpty != false, "a band should have no animation")
        try expect(held.layer?.opacity == TrackerGlowNSView.bandOpacity, "a band should hold its opacity")
    }

    /// The status geometry: a ring 2 points inside each disc's stroke (1.5 on the collapsed circle), its inner edge on a
    /// whole pixel; a glow dilated 1, blurred 1.5, at 0.15 opacity.
    private static func testPortraitStatusFollowsTheFilterValues() throws {
        func expectClose(_ value: CGFloat, _ expected: CGFloat, _ name: String, tolerance: CGFloat = 0.01) throws {
            try expect(abs(value - expected) < tolerance, "\(name) should be \(expected), got \(value)")
        }
        let master = TrackerPlateDesign.topLevel.statusGeometry
        let worker = TrackerPlateDesign.worker.statusGeometry
        let circle = TrackerPlateDesign.collapsedCircleStatus
        for (name, geometry, visible, outer) in [("master", master, 2, 25), ("worker", worker, 2, 20), ("circle", circle, 1.5, 12.5)] as [(String, TrackerPortraitStatusGeometry, CGFloat, CGFloat)] {
            try expectClose(geometry.outerRadius, outer, "\(name) disc outer radius")
            // The ring shows 2 points inside the stroke's inner edge (1.5 on the circle, whose centre is on a half
            // point), and runs under the stroke. Its inner edge sits a whole number of points from the centre's pixel.
            try expectClose(geometry.pathRadius - geometry.stroke / 2 - geometry.ringInnerRadius, visible, "\(name) visible ring width")
            let innerEdge = geometry.center.x - geometry.ringInnerRadius
            try expect(abs(innerEdge - innerEdge.rounded()) < 0.001, "\(name) ring's inner edge should land on a whole pixel, got \(innerEdge)")
            try expectClose(geometry.ringLineWidth, geometry.pathRadius - geometry.ringInnerRadius, "\(name) ring stroke width")
            try expectClose(geometry.glowOpacity(at: outer - 0.01), 0, "\(name) glow inside the disc")
            let edge = geometry.glowOpacity(at: outer)
            try expect(edge > 0.10 && edge < 0.12, "\(name) glow at the disc's edge should be about 0.112, got \(edge)")
            try expect(geometry.glowOpacity(at: outer + 1) < edge && geometry.glowOpacity(at: outer + 1) > 0.15 * 0.45, "\(name) glow should fall to half the peak by the dilated edge")
            try expect(geometry.glowOpacity(at: geometry.reach) < 0.001, "\(name) glow should fade out within its reach, got \(geometry.glowOpacity(at: geometry.reach))")
            try expect(geometry.glowOpacity(at: 0) == 0 && geometry.glowOpacity(at: 3 * outer) < 0.0001, "\(name) glow should be nothing in the disc and far away")
            let stops = geometry.glowStops
            try expect(stops.first?.location == 0 && stops.last?.location == 1, "\(name) stops should span the layer")
            try expect(zip(stops, stops.dropFirst()).allSatisfy { $0.location <= $1.location }, "\(name) stops should not run backwards")
            try expect(zip(stops.dropFirst(2), stops.dropFirst(3)).allSatisfy { $0.opacity >= $1.opacity }, "\(name) glow should only fall outward")
            try expect(stops[1].opacity == 0 && stops[2].opacity == edge && stops[1].location == stops[2].location, "\(name) glow should step in at the disc's edge")
            let frame = geometry.frame
            try expect(frame.minX == frame.minX.rounded() && frame.minY == frame.minY.rounded() && frame.width == frame.width.rounded() && frame.height == frame.height.rounded(), "\(name) layer should sit on whole points, got \(frame)")
            try expect(frame.minX <= geometry.center.x - geometry.reach && frame.maxX >= geometry.center.x + geometry.reach && frame.minY <= geometry.center.y - geometry.reach && frame.maxY >= geometry.center.y + geometry.reach, "\(name) layer should hold the glow's whole reach")
            try expectClose(geometry.layerCenter.x + frame.minX, geometry.center.x, "\(name) disc centre x in the layer")
            try expectClose(geometry.layerCenter.y + frame.minY, geometry.center.y, "\(name) disc centre y in the layer")
        }
        // Whatever the disc's centre, even on a half or a quarter point, the layer's frame stays on whole points.
        for center in [CGPoint(x: 12.5, y: 12.5), CGPoint(x: 100.25, y: 7.75), CGPoint(x: 30, y: 40.5)] {
            let geometry = TrackerPortraitStatusGeometry(center: center, pathRadius: 11.75, stroke: 1.5)
            let frame = geometry.frame
            try expect([frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0 == $0.rounded() }, "a layer for a disc at \(center) should sit on whole points, got \(frame)")
        }
        try expect(TrackerPortraitStatusGeometry.glowPeakOpacity == 0.15 && TrackerPortraitStatusGeometry.glowSigma == 1.5 && TrackerPortraitStatusGeometry.glowSpread == 1, "the glow should be tight")

        // The layers sit on the discs: the master's centre is the canvas', the worker's the list's worker indent.
        try expectClose(master.center.x, 25, "master status centre x")
        try expectClose(master.center.y, 27, "master status centre y")
        try expectClose(worker.center.x, 20 + TrackerPlateDesign.workerShift, "worker status centre x")
        try expectClose(worker.center.y, 22, "worker status centre y")
        try expectClose(circle.center.x, 12.5, "circle status centre")
        try expectClose(TrackerPlateDesign.collapsedCircleStroke, 1.5, "circle stroke")
    }

    /// Hosted views: a plate's status view exists exactly while its status is active (selection and hover do not hide
    /// it), and a collapsed row has one for each active worker only. Each view is hosted beside a control status; the
    /// control and every status view being configured proves the same update pass mounted the subject too, so a missing
    /// status view is a real absence and not a slow host. Nothing here reads an animation, which depends on the host's
    /// display and its reduce-motion setting; the ring's animations are tested on the view itself, and its mode in Core.
    private static func testPlateAndCircleStatusDrawsOnlyForActiveStatuses() throws {
        let controlGeometry = TrackerPortraitStatusGeometry(center: .zero, pathRadius: 40, stroke: 1)
        func statusViews(in view: NSView) -> [TrackerPortraitStatusNSView] {
            view.subviews.flatMap { subview in
                (subview as? TrackerPortraitStatusNSView).map { [$0] } ?? statusViews(in: subview)
            }
        }
        /// The status views the subject draws, and the control's.
        func host<V: View>(_ subject: V, _ description: String) throws -> (subject: [TrackerPortraitStatusNSView], control: TrackerPortraitStatusNSView) {
            let hosting = NSHostingView(rootView: VStack {
                subject
                TrackerPortraitStatus(geometry: controlGeometry, color: AppPalette.accent, ring: .spinning(nil))
            })
            hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
            let window = HeadlessWindow(size: CGSize(width: 320, height: 240))
            window.contentView = hosting
            window.show()
            defer { window.close() }
            func control() -> TrackerPortraitStatusNSView? {
                statusViews(in: hosting).first { $0.geometry == controlGeometry }
            }
            func unconfigured() -> Int {
                statusViews(in: hosting).filter { $0.geometry == nil }.count
            }
            let deadline = Date().addingTimeInterval(10)
            while (control() == nil || unconfigured() > 0), Date() < deadline {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            guard let control = control() else {
                throw TestFailure("\(description): the control status view never mounted (hosting subviews: \(hosting.subviews.count), status views: \(statusViews(in: hosting).count))")
            }
            try expect(unconfigured() == 0, "\(description): \(unconfigured()) status views never configured")
            return (statusViews(in: hosting).filter { $0 !== control }, control)
        }
        func plate(status: NSColor?, showsCursor: Bool = false) -> some View {
            TrackerNameplateBackground(
                role: .master, color: AppPalette.accent, showsCursor: showsCursor, isRecoloring: false,
                statusColor: status, ring: status == nil ? .none : .spinning(nil), text: EmptyView()
            )
        }
        let working = AppPalette.trackerWorking
        try expect(try host(plate(status: nil), "an idle plate").subject.isEmpty, "a plate with no active status should draw no status")
        let resting = try host(plate(status: working), "a working plate")
        try expect(resting.subject.count == 1, "a working plate should draw one status, got \(resting.subject.count)")
        try expect(resting.subject[0].ringMode == .spinning(nil), "a working plate with no tool should spin its ring")
        try expect(try host(plate(status: working, showsCursor: true), "a working plate under the cursor").subject.count == 1, "the cursor should not hide the status")

        func worker(_ id: String, state: String) -> TrackerRenderedSession {
            let session = TrackerSession(id: id, title: id, repoName: "Preview", agent: "claude", role: "worker", state: state)
            return TrackerRenderedSession(session: session, status: TrackerRenderer.status(for: session), groupColor: AppPalette.accent, recolorEditHint: nil)
        }
        let states = ["working", "idle", "blocked", "done", "needs-input", "stopped", "error"]
        let row = TrackerWorkerSummaryRow(workers: states.enumerated().map { worker("w\($0.offset)", state: $0.element) })
        let circles = try host(row, "a collapsed row").subject.filter { $0.ringMode != TrackerPortraitRing.none }
        try expect(circles.count == 4, "a collapsed row should draw a ring for each active worker only, got \(circles.count)")
    }

    /// The attached session's dot: the plates' paths put it `Space.row` across, its centre `Space.item` left of the disc's
    /// left edge and level with the disc's centre (the master's side diamonds'), in the gutter the list's padding leaves.
    /// A real tracker, at 1x and 2x, draws it whole there, on the attached session's plate only: the master's, the
    /// expanded worker's own, a collapsed worker's master's, and no plate's for a shell or nothing attached. Each dot is
    /// found by its share of the project colour over the window colour, so its size and centre are measured, and a clipped
    /// dot comes up short of its area.
    private static func testTheAttachedDotSitsBesideTheDiscWholeAndOnTheRightPlate() throws {
        func expectClose(_ value: CGFloat, _ expected: CGFloat, _ tolerance: CGFloat, _ name: String) throws {
            try expect(abs(value - expected) <= tolerance, "\(name) should be \(expected), got \(value)")
        }

        // The paths: 5 across, 10 left of the disc, level with its centre, and the master's level with its side diamond.
        let diameter = TrackerPlateDesign.attachedDotDiameter
        try expectClose(diameter, 5, 0, "dot diameter")
        try expectClose(TrackerPlateDesign.attachedDotInset, 10, 0, "dot distance from the disc's edge")
        for (name, artwork) in [("master", TrackerPlateDesign.topLevel), ("worker", TrackerPlateDesign.worker)] {
            let dot = artwork.attachedDot.boundingRect
            let disc = artwork.discEdge.boundingRect
            try expectClose(dot.width, diameter, 0.001, "\(name) dot width")
            try expectClose(dot.height, diameter, 0.001, "\(name) dot height")
            try expectClose(dot.midX, disc.minX - TrackerPlateDesign.attachedDotInset, 0.001, "\(name) dot centre x against the disc's left edge")
            try expectClose(dot.midY, disc.midY, 0.001, "\(name) dot centre y against the disc's centre")
            try expect(dot.maxX < disc.minX, "the \(name) dot should clear the disc")
        }
        let diamond = TrackerPlateDesign.topLevel.ornaments.first { $0.role == .project }?.path.boundingRect ?? .null
        try expectClose(TrackerPlateDesign.topLevel.attachedDot.boundingRect.midY, diamond.midY, 0.001, "master dot centre y against its side diamond's")
        // The master's dot reaches furthest left, 12.5 past its row, which the list's leading padding leaves room for.
        try expect(TrackerListMetrics.sidePadding + TrackerPlateDesign.topLevel.attachedDot.boundingRect.minX >= 0, "the master's dot should sit inside the list's gutter")

        // The pixels: a real tracker with an expanded master and its worker, a collapsed master and its worker, and a shell.
        let size = CGSize(width: 340, height: 600)
        func components(_ color: NSColor?) throws -> [CGFloat] {
            guard let rgb = color?.usingColorSpace(.deviceRGB) else {
                throw TestFailure("a colour should convert to RGB")
            }
            return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        }
        let indigo = AppPalette.displayColor("indigo").map(TrackerNameplateColor.barLightness)
        let background = try components(AppPalette.window)
        let toward = try zip(components(indigo), background).map { $0 - $1 }
        let towardLength = toward.map { $0 * $0 }.reduce(0, +)

        /// The dot's share of each pixel in a window `radius` around `centre` (list points), as its area in points and its
        /// centroid.
        func dot(in bitmap: NSBitmapImageRep, scale: CGFloat, around centre: CGPoint, radius: CGFloat) throws -> (area: CGFloat, centroid: CGPoint) {
            var weight: CGFloat = 0
            var sum = CGPoint.zero
            let xs = Int((centre.x - radius) * scale)..<Int((centre.x + radius) * scale)
            let ys = Int((centre.y - radius) * scale)..<Int((centre.y + radius) * scale)
            for y in ys {
                for x in xs {
                    let pixel = try components(bitmap.colorAt(x: x, y: y))
                    let share = zip(zip(pixel, background), toward).map { ($0.0 - $0.1) * $1 }.reduce(0, +) / towardLength
                    let coverage = min(max(share, 0), 1)
                    weight += coverage
                    sum.x += coverage * (CGFloat(x) + 0.5) / scale
                    sum.y += coverage * (CGFloat(y) + 0.5) / scale
                }
            }
            return (weight / (scale * scale), weight == 0 ? .zero : CGPoint(x: sum.x / weight, y: sum.y / weight))
        }

        /// The row tops: the first plate sits `selectedPanelGap` under the panel, the next after a row and a gap.
        let masterTop = SelectedSessionPanel.canvasSize.height + TrackerListMetrics.selectedPanelGap
        let workerTop = masterTop + TrackerNameplateRole.master.canvasSize.height + TrackerListMetrics.spacing
        let collapsedTop = workerTop + TrackerNameplateRole.worker.canvasSize.height + TrackerListMetrics.spacing
        let gutter = TrackerListMetrics.sidePadding
        let masterDot = { (top: CGFloat) in
            CGPoint(x: gutter - TrackerPlateDesign.attachedDotInset, y: top + TrackerPlateDesign.topLevelPortraitCenter.y)
        }
        let workerDot = CGPoint(
            x: gutter + TrackerPlateDesign.workerPortraitCenter.x - TrackerPlateDesign.workerDiscDiameter / 2 - TrackerPlateDesign.attachedDotInset,
            y: workerTop + TrackerPlateDesign.workerPortraitCenter.y
        )
        let positions = ["expanded master": masterDot(masterTop), "expanded worker": workerDot, "collapsed master": masterDot(collapsedTop)]
        let cases: [(attached: String?, shows: String?)] = [
            ("m", "expanded master"), ("m-w", "expanded worker"), ("n", "collapsed master"), ("n-w", "collapsed master"),
            ("sh", nil), ("gone", nil), (nil, nil),
        ]
        let expectedArea = CGFloat.pi * diameter * diameter / 4
        for scale in [CGFloat(1), CGFloat(2)] {
            for testCase in cases {
                func session(_ id: String, role: String, parent: String = "") -> TrackerSession {
                    TrackerSession(id: id, title: id, repoName: "Repo", displayColor: "indigo", agent: role == "shell" ? "shell" : "codex", role: role, state: "idle", parentID: parent)
                }
                let store = RuntimeStore(sourceLabel: "test", currentTerminalSessionID: testCase.attached, expandedMasterIDs: ["m"])
                store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "repo", name: "Repo", color: "indigo", sessions: [
                    session("m", role: "master"), session("m-w", role: "worker", parent: "m"),
                    session("n", role: "master"), session("n-w", role: "worker", parent: "n"), session("sh", role: "shell"),
                ])])))
                let view = NSHostingView(rootView: TrackerRootView(
                    store: store,
                    navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
                    newSessionPresenter: NewSessionSheetPresenter(),
                    destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
                )
                .frame(width: size.width, height: size.height)
                .background(AppPalette.window.swiftUI))
                view.frame = NSRect(origin: .zero, size: size)
                let window = HeadlessWindow(size: size, scale: scale)
                window.contentView = view
                window.show()
                defer { window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                let bitmap = try snapshot(view, size: size, scale: scale)

                for (name, centre) in positions {
                    let found = try dot(in: bitmap, scale: scale, around: centre, radius: diameter / 2 + 3)
                    let context = "\(name) with \(testCase.attached ?? "nothing") attached at \(Int(scale))x"
                    guard testCase.shows == name else {
                        try expect(found.area < 0.5, "the \(context) should have no dot, got an area of \(found.area)")
                        continue
                    }
                    try expectClose(found.area, expectedArea, 1, "the \(context) dot's area, whole and unclipped")
                    try expectClose(found.centroid.x, centre.x, 0.15, "the \(context) dot's centre x")
                    try expectClose(found.centroid.y, centre.y, 0.15, "the \(context) dot's centre y")
                }
            }
        }
    }

    private static func testTrackerPlatesKeepTheDesignsProportions() throws {
        func expectClose(_ value: CGFloat, _ expected: CGFloat, _ name: String) throws {
            try expect(abs(value - expected) < 0.01, "\(name) should be \(expected), got \(value)")
        }
        func expectRect(_ path: Path, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ name: String) throws {
            let box = path.boundingRect
            let matches = abs(box.minX - x0) < 0.01 && abs(box.minY - y0) < 0.01 && abs(box.maxX - x1) < 0.01 && abs(box.maxY - y1) < 0.01
            try expect(matches, "\(name) should span x \(x0)..\(x1), y \(y0)..\(y1), got \(box)")
        }
        let shift = TrackerPlateDesign.workerShift

        // Sizes: each canvas starts 2 above its row, which is the disc's height and the plate's width; canvases sit on 5s.
        try expectClose(TrackerPlateDesign.topLevel.size.width, 265, "master canvas width")
        try expectClose(TrackerPlateDesign.topLevel.size.height, 55, "master canvas height")
        try expectClose(TrackerPlateDesign.topLevelSize.height, 50, "master row height")
        try expectClose(TrackerPlateDesign.topLevelSize.width, 260, "master row width, 260 by decision")
        try expectClose(TrackerPlateDesign.svgDiscInset, 2, "canvas start above its row")
        try expectClose(TrackerPlateDesign.worker.size.width, 255, "worker canvas width")
        try expectClose(TrackerPlateDesign.worker.size.height, 45, "worker canvas height")
        try expectClose(TrackerPlateDesign.workerSize.width, 232 + shift - 2, "worker row width")
        try expectClose(TrackerPlateDesign.workerSize.height, 40, "worker row height")

        // The paths are the SVGs', moved onto whole points and the 5pt grid: the master's back by the SVG's slip and 2
        // left so its disc spans 0-50 (its right edge stays at 260), the worker's to the list's worker indent.
        let master = TrackerPlateDesign.topLevel
        try expectRect(master.tab ?? Path(), 25, 3.5, 255, 15.5, "master project tab")
        try expectRect(master.body, 25, 15.5, 260, 50.5, "master body")
        try expectRect(master.titleStrip, 28, 17.5, 258, 36.5, "master title strip")
        try expectRect(master.bar ?? Path(), 28, 38.5, 258, 48.5, "master project bar")
        try expectRect(master.disc, 1.5, 3.5, 48.5, 50.5, "master disc")
        try expectRect(master.discEdge, 0, 2, 50, 52, "master disc edge")
        try expectClose(master.discStroke, 3, "master disc stroke")
        try expect(master.snippetStrip == nil, "the master's snippet sits on its project bar")
        let worker = TrackerPlateDesign.worker
        try expectRect(worker.body, 22 + shift - 2, 4.5, 232 + shift - 2, 39.5, "worker body")
        try expectRect(worker.titleStrip, 25 + shift - 2, 6.5, 230 + shift - 2, 25.5, "worker title strip")
        try expectRect(worker.snippetStrip ?? Path(), 25 + shift - 2, 27.5, 230 + shift - 2, 37.5, "worker snippet strip")
        try expectRect(worker.discEdge, 2 + shift - 2, 2, 42 + shift - 2, 42, "worker disc edge")
        try expectClose(worker.discStroke, 2, "worker disc stroke")
        try expect(worker.tab == nil && worker.bar == nil && worker.ornaments.isEmpty, "the worker has no tab, project bar or ornaments")

        // The ornaments reach 2.17 past the disc: the crown pieces above and below, the diamonds on its sides.
        let ornamentBox = master.ornaments.reduce(CGRect.null) { $0.union($1.path.boundingRect) }
        try expectRect(Path(ornamentBox), -2.1739, -0.1739, 52.1738, 54.1739, "master ornaments")

        // The disc is the row's height, and the row's centre is the disc's, in the row's points.
        try expectClose(TrackerPlateDesign.topLevelDiscDiameter, 2 * (23.5 + 1.5), "master disc outer diameter")
        try expectClose(TrackerPlateDesign.workerDiscDiameter, 2 * (19 + 1), "worker disc outer diameter")
        try expectClose(TrackerPlateDesign.topLevelPortraitCenter.y, TrackerPlateDesign.topLevelSize.height / 2, "master disc centre in its row")
        try expectClose(TrackerPlateDesign.workerPortraitCenter.y, TrackerPlateDesign.workerSize.height / 2, "worker disc centre in its row")
        try expectClose(TrackerPlateDesign.topLevelPortraitCenter.y + TrackerPlateDesign.svgDiscInset, 27, "master disc centre in its canvas")
        try expectClose(TrackerPlateDesign.workerPortraitCenter.y + TrackerPlateDesign.svgDiscInset, 22, "worker disc centre in its canvas")
        try expectClose(TrackerPlateDesign.workerPortraitCenter.x - TrackerPlateDesign.topLevelPortraitCenter.x, 15, "worker disc indent")
        try expectClose(
            TrackerNameplateRole.worker.portraitOrigin.x - TrackerNameplateRole.master.portraitOrigin.x,
            20,
            "worker portrait indent"
        )

        // The discs sit on the 5pt grid, and plate text starts 5 past the disc's round edge: the master's disc spans
        // 0-50, the worker's 20-60; the panel's ends at 70, and its text sits 10 past it to clear the Q's spike.
        try expectRect(master.discEdge.offsetBy(dx: 0, dy: -TrackerPlateDesign.svgDiscInset), 0, 0, 50, 50, "master disc in its row")
        try expectRect(worker.discEdge.offsetBy(dx: 0, dy: -TrackerPlateDesign.svgDiscInset), 20, 0, 60, 40, "worker disc in its row")
        try expectClose(TrackerNameplateRole.topLevelTextX, 55, "master text column")
        try expectClose(TrackerNameplateRole.workerTextX, 65, "worker text column")
        try expectClose(SelectedSessionPanel.textX, 80, "selected-session panel text column")
        try expectClose(TrackerNameplateRole.master.snippetX, TrackerNameplateRole.master.titleX, "master snippet under the title")

        // Every layer of a portrait sits at a whole-point origin. A frame on a half point snaps to a whole pixel at 1x
        // and drifts half a pixel off the disc the plate's canvas draws at exact geometry.
        for role in [TrackerNameplateRole.master, .worker] {
            for (name, value) in [("x", role.portraitOrigin.x), ("y", role.portraitOrigin.y), ("diameter", role.portraitDiameter)] {
                try expect(value == value.rounded(), "the \(role) portrait's \(name) should be a whole point, got \(value)")
            }
            let logoSide = role.logoSide
            let logoInset = (role.portraitDiameter - logoSide) / 2
            try expect(logoSide == logoSide.rounded() && logoInset == logoInset.rounded(), "the \(role) logo should sit on whole points, got side \(logoSide) at \(logoInset)")
        }

        // The list's gaps are the user's, each a whole number of points, from the visible bottom of the item above.
        try expectClose(TrackerListMetrics.spacing, 10, "every gap in the list")
        try expectClose(TrackerListMetrics.contentWidth, SelectedSessionPanel.canvasSize.width + TrackerPlateDesign.glowBandWidth, "tracker content width, the panel's and its band's")
        try expectClose(SelectedSessionPanel.canvasSize.width, TrackerPlateDesign.topLevelSize.width, "selected-session panel width, the master plate's")
        try expectClose(SelectedSessionPanel.canvasSize.height, 75, "selected-session panel height")
        try expectClose(TrackerListMetrics.selectedPanelGap, 40, "gap between the selected-session panel and the first disc")

        // The collapsed workers sit right under the disc's row, 40 right of its left edge, and fill the plate's width.
        let discLeft = TrackerNameplateRole.master.portraitOrigin.x
        try expectClose(TrackerNameplateRole.circlesX - discLeft, 40, "first collapsed circle's offset from the disc's left edge")
        try expectClose(TrackerPlateDesign.collapsedCircleDiameter, 25, "collapsed circle diameter")
        try expectClose(TrackerPlateDesign.collapsedCircleGap, 5, "gap between collapsed circles")
        try expect(TrackerWorkerSummary.maxCircles == 7, "a master's 260pt collapsed row should hold seven circles, got \(TrackerWorkerSummary.maxCircles)")
        let rowRight = TrackerNameplateRole.circlesX
            + CGFloat(TrackerWorkerSummary.maxCircles) * TrackerPlateDesign.collapsedCircleDiameter
            + CGFloat(TrackerWorkerSummary.maxCircles - 1) * TrackerPlateDesign.collapsedCircleGap
        try expect(rowRight <= TrackerPlateDesign.topLevelSize.width && rowRight + TrackerPlateDesign.collapsedCircleGap + TrackerPlateDesign.collapsedCircleDiameter > TrackerPlateDesign.topLevelSize.width,
                   "the collapsed row should hold as many circles as fit inside the plate, ending at \(rowRight)")
        try expectClose(TrackerNameplateRole.master.rowHeight(showsCircles: true), 75, "master row height with collapsed circles")
        try expectClose(TrackerNameplateRole.worker.rowHeight(showsCircles: false), 40, "worker row height")

        // The master's crown pieces and ring are live: its row's hit and hover shape reaches the canvas's extents, above
        // the row and below it, past the crown's tip. The worker's has no artwork past its frame.
        let masterRow = CGRect(origin: .zero, size: TrackerPlateDesign.topLevelSize)
        let masterHit = RowHitShape(outset: TrackerNameplateRole.master.hitOutset).path(in: masterRow).boundingRect
        try expect(masterHit.minY <= -TrackerPlateDesign.svgDiscInset, "master hit shape top should reach the canvas's top, got \(masterHit.minY)")
        let crownBottom = ornamentBox.maxY - TrackerPlateDesign.svgDiscInset
        try expect(masterHit.maxY >= crownBottom, "master hit shape bottom should reach the crown's tip at \(crownBottom), got \(masterHit.maxY)")
        try expectClose(masterHit.width, TrackerPlateDesign.topLevelSize.width, "master hit shape width")
        try expect(TrackerNameplateRole.worker.hitOutset == 0, "the worker's row has no artwork past its frame")

        // The agent badge hangs 5 past its disc's left edge and bottom: on a master's row, left of the frame and below it,
        // on a worker's, below it. Every point of its rim is live, but the shape stays the circle: its square's corners are
        // not. The row sits off the origin, so the badge has to follow the row.
        try expectClose(TrackerPlateDesign.badgeDiameter, TrackerPlateDesign.collapsedCircleDiameter, "the badge is as big as a collapsed worker's circle")
        try expectClose(TrackerPlateDesign.badgeLogoSide, TrackerPlateDesign.collapsedLogoSide, "its logo is the circle's logo size")
        for role in [TrackerNameplateRole.master, .worker] {
            try expectClose(role.portraitOrigin.x - role.badgeOrigin.x, TrackerPlateDesign.badgeOverhang, "\(role)'s badge hangs the overhang past the disc's left edge")
            try expectClose(
                role.badgeOrigin.y + TrackerPlateDesign.badgeDiameter - (role.portraitOrigin.y + role.portraitDiameter),
                TrackerPlateDesign.badgeOverhang,
                "\(role)'s badge hangs the overhang below the disc"
            )
            try expect(role.badgeOrigin.x == role.badgeOrigin.x.rounded() && role.badgeOrigin.y == role.badgeOrigin.y.rounded(), "\(role)'s badge frame sits on whole points")
            let row = CGRect(origin: CGPoint(x: 7, y: 3), size: role.canvasSize)
            let hit = RowHitShape(outset: role.hitOutset, overhang: role.badgeHitShape).path(in: row)
            let radius = TrackerPlateDesign.badgeDiameter / 2
            let centre = CGPoint(x: row.minX + role.badgeOrigin.x + radius, y: row.minY + role.badgeOrigin.y + radius)
            try expect(centre.y + radius > row.maxY + role.hitOutset, "\(role)'s badge should hang past the row's own hit shape")
            for step in 0..<16 {
                let angle = CGFloat(step) * .pi / 8
                let rim = CGPoint(x: centre.x + (radius - 0.5) * cos(angle), y: centre.y + (radius - 0.5) * sin(angle))
                try expect(hit.contains(rim), "\(role)'s hit shape should take in the badge's rim at \(rim)")
            }
            let squareCorner = CGPoint(x: centre.x - radius + 0.5, y: centre.y + radius - 0.5)
            try expect(!hit.contains(squareCorner), "\(role)'s hit shape should not take in the badge square's corner at \(squareCorner)")
        }
        try expect(TrackerNameplateRole.master.badgeOrigin.x < 0, "a master's badge hangs left of its row")
    }

    private static func testElapsedTimeShowsOnlyWhileWorkingAndIsLiveOnlyWhenCounting() throws {
        func session(role: String, state: String, lifecycle: String = "active", since: Date? = nil, seed: Int? = nil) -> TrackerSession {
            TrackerSession(
                id: "session", title: "Session", repoName: "Preview", agent: "codex", role: role, state: state,
                lifecycle: lifecycle, elapsedSince: since, elapsedSeedMS: seed
            )
        }

        // Masters, shell rows and workers alike show their time only while they work.
        for role in ["master", "worker"] {
            try expect(TrackerRenderer.durationLabel(for: session(role: role, state: "working", seed: 125_000)) == "0:02:05", "a working \(role) should show its time")
            try expect(TrackerRenderer.durationLabel(for: session(role: role, state: "idle", seed: 125_000)).isEmpty, "an idle \(role) should show no time")
        }
        let stopped = session(role: "master", state: "stopped", lifecycle: "stopped", seed: 0)
        try expect(TrackerRenderer.durationLabel(for: stopped).isEmpty, "a stopped session has no time to show")

        // Only a time that counts from an instant is live, and only while it shows.
        let since = Date().addingTimeInterval(-60)
        typealias Time = TrackerElapsedTime<EmptyView>
        try expect(Time.isLive(session: session(role: "master", state: "working", since: since)), "a working session counting from an instant is live")
        try expect(!Time.isLive(session: session(role: "worker", state: "idle", since: since)), "an idle session shows no time, so it is not live")
        try expect(!Time.isLive(session: session(role: "master", state: "working", seed: 125_000)), "a fixed time is not live")
        try expect(!Time.isLive(session: session(role: "master", state: "working")), "a session with no time is not live")
    }

    /// One timer serves every reader: its rate is the clock's, not the number of subscribers times it.
    private static func testDurationClockHasOneTimerWhateverTheSubscribers() throws {
        try expect(TrackerPulseClock.durations.framesPerSecond == 1, "live times should tick once a second")
        let clock = TrackerPulseClock(framesPerSecond: 20)
        try expect(!clock.isRunning, "a clock with no subscribers should not run")
        for _ in 0..<100 { clock.subscribe() }
        try expect(clock.timersStarted == 1, "100 subscribers should share one timer, got \(clock.timersStarted)")
        let start = Date()
        try expect(waitUntil { clock.ticks >= 4 }, "the clock should tick")
        let elapsed = Date().timeIntervalSince(start)
        try expect(Double(clock.ticks) <= clock.framesPerSecond * elapsed + 2, "100 subscribers should not multiply the ticks: \(clock.ticks) in \(elapsed)s")
        for _ in 0..<99 { clock.unsubscribe() }
        try expect(clock.isRunning, "the clock should run while one subscriber is left")
        clock.unsubscribe()
        try expect(!clock.isRunning, "the clock should stop with its last subscriber")
    }

    /// Hosted views: fixed, empty and hidden times subscribe to nothing; live ones share the clock's one timer, and it
    /// stops when they go.
    private static func testOnlyLiveElapsedTimesSubscribeToTheDurationClock() throws {
        let clock = TrackerPulseClock.durations
        func session(state: String, role: String, since: Date? = nil, seed: Int? = nil) -> TrackerSession {
            TrackerSession(
                id: "session", title: "Session", repoName: "Preview", agent: "codex", role: role, state: state,
                elapsedSince: since, elapsedSeedMS: seed
            )
        }
        let since = Date().addingTimeInterval(-60)
        let fixed = session(state: "working", role: "master", seed: 125_000)
        let hidden = session(state: "idle", role: "master", since: since)
        let live = session(state: "working", role: "master", since: since)
        func column(_ sessions: [TrackerSession]) -> AnyView {
            AnyView(VStack {
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
                    TrackerElapsedTime(session: session) { Text($0) }
                }
            })
        }
        let idleEntries = Array(repeating: fixed, count: 30) + Array(repeating: hidden, count: 30)
        let hosting = NSHostingView(rootView: column(idleEntries))
        let window = HeadlessWindow(size: CGSize(width: 300, height: 200))
        window.contentView = hosting
        window.show()
        defer { window.close() }
        let startedBefore = clock.timersStarted
        pump(0.3)
        try expect(!clock.isRunning && clock.timersStarted == startedBefore, "fixed and hidden times should not start the clock")

        hosting.rootView = column(idleEntries + Array(repeating: live, count: 30))
        try expect(waitUntil { clock.isRunning }, "live times should start the clock")
        try expect(clock.timersStarted == startedBefore + 1, "30 live times should share one timer, got \(clock.timersStarted - startedBefore)")

        hosting.rootView = column(idleEntries)
        try expect(waitUntil { !clock.isRunning }, "the clock should stop when the live times go")
    }

    /// The cast bar's inside runs in Core Animation: a learned duration gets one linear fill to full at the typical
    /// duration (kept under reduce motion) and a pulse from then on (none under reduce motion), an unknown one a repeating shimmer (none under reduce
    /// motion), a finishing cast neither, and nothing animates outside a window.
    private static func testCastFillAnimatesOnlyWhileCastingInAWindow() throws {
        let window = HeadlessWindow(size: CGSize(width: 300, height: 40))
        let started = Date().addingTimeInterval(-2)
        let bash = TrackerCast(tool: "Bash", startedAt: started, typicalMS: 6000)
        let overrun = TrackerCast(tool: "Bash", startedAt: Date().addingTimeInterval(-9), typicalMS: 6000)
        let mcp = TrackerCast(tool: "mcp__linear__save_issue", startedAt: started, typicalMS: 0)

        let outside = TrackerCastFillNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 13))
        outside.configure(cast: bash, isFinishing: false, reduceMotion: false)
        try expect(outside.fillAnimation == nil && outside.pulseAnimation == nil, "a bar outside a window should not animate")

        let fill = TrackerCastFillNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 13))
        window.contentView = fill
        fill.configure(cast: bash, isFinishing: false, reduceMotion: false)
        guard let animation = fill.fillAnimation, let pulse = fill.pulseAnimation else {
            throw TestFailure("a cast with a learned duration should fill, then pulse")
        }
        try expect(abs(animation.duration - 4) < 0.1, "2s into a 6s tool the fill should run 4s to full, got \(animation.duration)")
        try expect(abs(pulse.beginTime - CACurrentMediaTime() - 4) < 0.2, "the pulse should start when the bar is full")
        try expect(pulse.repeatCount == .infinity && pulse.autoreverses, "the pulse should breathe until the tool ends")
        try expect(!fill.isShimmering, "a learned duration should not shimmer")

        fill.configure(cast: overrun, isFinishing: false, reduceMotion: false)
        try expect(fill.fillAnimation == nil && fill.pulseAnimation != nil, "an overrunning tool should hold full and pulse at once")
        fill.configure(cast: overrun, isFinishing: false, reduceMotion: true)
        try expect(fill.pulseAnimation == nil, "reduce motion should hold the full bar steady")
        fill.configure(cast: bash, isFinishing: false, reduceMotion: true)
        try expect(fill.fillAnimation != nil && fill.pulseAnimation == nil, "reduce motion should keep the fill, with no pulse")

        fill.configure(cast: mcp, isFinishing: false, reduceMotion: false)
        try expect(fill.isShimmering && fill.fillAnimation == nil && fill.pulseAnimation == nil, "an unknown duration should shimmer instead of filling")
        fill.configure(cast: mcp, isFinishing: false, reduceMotion: true)
        try expect(!fill.isShimmering, "reduce motion should stop the shimmer")
        fill.configure(cast: bash, isFinishing: true, reduceMotion: false)
        try expect(fill.fillAnimation == nil && fill.pulseAnimation == nil && !fill.isShimmering, "a finishing cast should hold full and flash, nothing else")
    }

    private static func testPlateTimeColumnFitsRunsPastNinetyNineHours() throws {
        let hundredHours = 100 * 3600 * 1000
        let usual = TrackerSession.unitTime(TrackerSession.formatElapsed(80_000) ?? "")
        let long = TrackerSession.unitTime(TrackerSession.formatElapsed(hundredHours) ?? "")
        try expect(usual == "01m20s", "an 80-second run should read 01m20s, got \(usual)")
        try expect(long == "100h00m", "a 100-hour run should read 100h00m, got \(long)")

        let font = AppFonts.trackerTime
        for time in [usual, long] {
            let column = TrackerNameplateRole.timeWidth(for: time)
            let ink = (time as NSString).size(withAttributes: [.font: font]).width
            try expect(column >= ink, "the time column for \(time) should hold its \(ink)pt of text, got \(column)")
        }
        try expect(
            TrackerNameplateRole.timeWidth(for: long) > TrackerNameplateRole.timeWidth(for: usual),
            "the 100-hour time should get a wider column"
        )

        // On both plates the title takes the row up to a gap short of the time, whatever the time's width, and the
        // whole column with no time.
        for role in [TrackerNameplateRole.master, .worker] {
            for time in [usual, long] {
                let titleRight = role.titleX + role.titleWidth(time: time)
                let timeLeft = role.textRightEdge - TrackerNameplateRole.timeWidth(for: time)
                try expect(abs(timeLeft - titleRight - TrackerNameplateRole.titleTimeGap) < 0.01, "the \(role) title should stop a gap short of \(time)")
            }
            try expect(role.titleX + role.titleWidth(time: "") == role.textRightEdge, "a \(role) with no time gives its title the whole column")
        }
    }

    /// Renders the panel's plate and reads the frame's right-hand corners, on the border outside the title strip and the
    /// bar: each arc is the frame's colour, and outside it is clear. The SVG's clip group has a dark copy of the title
    /// strip, which must not reach past the strip.
    @MainActor
    private static func testSelectedSessionPanelFrameKeepsItsRoundedCorners() throws {
        let content = SelectedSessionPanelContent(title: "", id: "", projectName: "", projectColor: AppPalette.accent)
        let renderer = ImageRenderer(content: SelectedSessionPanel(content: content, onCopyID: { _ in }))
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            throw TestFailure("the panel should render to an image")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try expect(bitmap.pixelsWide == 520 && bitmap.pixelsHigh == 150, "the panel should render 260 x 75 at 2x, got \(bitmap.pixelsWide) x \(bitmap.pixelsHigh)")
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(x * 2), y: Int(y * 2))?.usingColorSpace(.sRGB)
        }
        guard let arc = pixel(258.5, 24.5), let outside = pixel(259.5, 22) else {
            throw TestFailure("the corner pixels should be readable")
        }
        try expect(outside.alphaComponent < 0.1, "outside the frame's corner should be clear, got alpha \(outside.alphaComponent)")
        try expect(arc.alphaComponent > 0.9 && arc.redComponent > 0.22, "the frame's arc at its top-right corner should be the frame's colour, got \(arc)")
        guard let bottomArc = pixel(258.5, 65) else {
            throw TestFailure("the bottom-right pixel should be readable")
        }
        try expect(bottomArc.alphaComponent > 0.9 && bottomArc.redComponent > 0.22, "the frame's arc at its bottom-right corner should be the frame's colour, got \(bottomArc)")
    }

    private static func testSelectedSessionPanelNamesTheAttachedSessionsProject() throws {
        let master = TrackerSession(id: "qm-attached", title: "Fix bug", repoName: "Preview", role: "master")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [TrackerRepo(id: "preview", name: "Preview", sessions: [master])])
        let tracker = TrackerRenderer.tracker(snapshot)

        let attached = SelectedSessionPanelContent.make(currentTerminalSessionID: "qm-attached", tracker: tracker)
        guard attached.id == "qm-attached", attached.projectName == "Preview" else {
            throw TestFailure("the panel should name the attached session's project, got \(attached.id) / \(attached.projectName)")
        }
        let shell = SelectedSessionPanelContent.make(currentTerminalSessionID: nil, tracker: tracker)
        guard shell.projectName.isEmpty else {
            throw TestFailure("a shell with no attached session should show no project")
        }
    }

    private static func testWorkerSummaryShowsOneCirclePerWorkerAndCountsTheRest() throws {
        func entries(workerCount: Int) throws -> [TrackerWorkerSummary.Entry] {
            let master = TrackerSession(id: "master", title: "Master", repoName: "Preview", role: "master")
            let sessions = [master] + (0..<workerCount).map { index in
                TrackerSession(
                    id: "worker-\(index)",
                    title: "Worker \(index)",
                    repoName: "Preview",
                    agent: index % 2 == 0 ? "codex" : "claude",
                    role: "worker",
                    state: index % 3 == 0 ? "working" : "idle",
                    parentID: master.id
                )
            }
            var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
            snapshot.tracker = TrackerSnapshot(repos: [TrackerRepo(id: "preview", name: "Preview", sessions: sessions)])
            guard let group = TrackerRenderer.tracker(snapshot).repos.first?.groups.first else {
                throw TestFailure("tracker renderer should keep the master group")
            }
            return TrackerWorkerSummary.circles(for: group.workers)
        }
        func workerIDs(_ entries: [TrackerWorkerSummary.Entry]) -> [String] {
            entries.compactMap { entry in
                if case .worker(let worker) = entry { worker.session.id } else { nil }
            }
        }

        // Every worker gets a circle, in the order the expanded list shows them, while they fit.
        let fit = TrackerWorkerSummary.maxCircles
        try expect(fit >= 2, "circle capacity should be a small positive number, got \(fit)")
        let fitting = try entries(workerCount: fit)
        try expect(workerIDs(fitting) == (0..<fit).map { "worker-\($0)" }, "workers that fit should each show, in order")
        try expect(fitting.count == fit, "\(fit) workers should show \(fit) circles, got \(fitting.count)")

        // One more, and the last slot becomes a "+N" circle counting the workers past the first fit - 1.
        let crowded = try entries(workerCount: fit + 3)
        try expect(crowded.count == fit, "more workers than fit should show \(fit) circles, got \(crowded.count)")
        try expect(workerIDs(crowded) == (0..<fit - 1).map { "worker-\($0)" }, "the first \(fit - 1) workers should show, in order")
        guard case .overflow(let hiddenWorkers) = crowded[fit - 1] else {
            throw TestFailure("the last circle should be the overflow circle")
        }
        try expect(hiddenWorkers == 4, "overflow should count the \(fit + 3 - (fit - 1)) workers past the shown ones, got \(hiddenWorkers)")
    }

    private static func testDevBackendBeatsGlobalPathInSourceCheckout() throws {
        let fixture = try devBackendFixture()
        let globalQM = fixture.go.deletingLastPathComponent().appendingPathComponent("qm")
        try writeExecutable("#!/bin/sh\necho old qm\n", to: globalQM)
        let backend = AppBackendResolver.resolve(arguments: [], environment: fixture.environment,
                                                workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        try expect(backend.source == .dev && backend.executablePath == fixture.go.path, "source checkout should use go")
        try expect(backend.command("start")?.arguments == ["run", ".", "daemon", "start", "--build-from", fixture.workingDirectory.path],
                   "dev start should build a stable daemon through Go")
    }

    private static func testPackagedBundleBeatsDevAndGlobalBackends() throws {
        let fixture = try appBackendFixture()
        let backend = AppBackendResolver.resolve(arguments: [], environment: fixture.environment,
                                                workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        try expect(backend.source == .bundled && backend.executablePath == fixture.qm.path, "bundle should use its qm")
    }

    private static func testAppChildProcessEnvironmentAppliesBackendAfterNormalizedPath() throws {
        let fixture = try appBackendFixture()
        let backend = LaunchConfiguration.load(
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            bundle: fixture.bundle
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

        try expect(env["PATH"]?.contains("/usr/bin") == true, "normalized PATH should remain available")
        try expect(env["QUESTMASTER_BIN"] == backend.executablePath, "child env should expose backend executable")
        try expect(env["QUESTMASTER_STATE_ROOT"] == backend.stateRoot, "child env should expose state root")
        try expect(env["QUESTMASTER_HOME"] == nil, "child env should clear legacy quest home")
        try expect(env["QUESTMASTER_PATH_PREFIX"] == nil, "shim prefix should come from daemon record")
        try expect(env["QUESTMASTER_QM"] == nil, "child env should not preserve app override input")
        try expect(env["TMUX"] == nil && env["TMUX_PANE"] == nil && env["TMUX_TMPDIR"] == nil, "child env should strip tmux variables")
    }

    private static func testDaemonRecordFeedsTerminalEnvironment() throws {
        let fixture = try appBackendFixture()
        let config = LaunchConfiguration.load(environment: fixture.environment,
                                              workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        let shim = fixture.root.appendingPathComponent("daemon-shims").path
        let json = try String(data: JSONSerialization.data(withJSONObject: [
            "running": true, "root": fixture.stateRoot.path, "identity": "canonical",
            "socket": fixture.root.appendingPathComponent("daemon.sock").path,
            "executable": fixture.qm.path, "shim_directory": shim,
            "build": "different", "generation": 1, "accepting": true,
        ]), encoding: .utf8) ?? ""
        try writeExecutable("#!/bin/sh\nprintf '%s\\n' '\(json)'\n", to: fixture.qm)
        let previous = AppBackendEnvironment.current
        defer { if let previous { AppBackendEnvironment.activate(previous) } }
        AppBackendEnvironment.activate(config.backend)
        _ = try DaemonConnection(config: config).record()
        let env = appChildProcessEnvironment(environment: fixture.environment, loginEnvironment: [:], backend: config.backend)
        try expect(env["QUESTMASTER_BIN"] == fixture.qm.path, "terminal should use executable from daemon record")
        try expect(env["QUESTMASTER_PATH_PREFIX"] == shim, "terminal should use daemon-owned shim path")
        try expect(env["PATH"]?.split(separator: ":").first.map(String.init) == shim, "daemon shim should be first on PATH")
    }

    private static func testTmuxStartupScriptScopesAppBackendEnvironmentToSession() throws {
        let fixture = try appBackendFixture()
        let backend = LaunchConfiguration.load(
            environment: fixture.environment,
            workingDirectory: fixture.workingDirectory.path,
            bundle: fixture.bundle
        ).backend
        let env = [
            "HOME": fixture.root.appendingPathComponent("home", isDirectory: true).path,
            "SHELL": "/tmp/custom shell/zsh",
            "PATH": "/test/prefix:/usr/bin",
            "QUESTMASTER_APP": "1",
            "QUESTMASTER_STATE_ROOT": backend.stateRoot,
            "QUESTMASTER_BIN": backend.executablePath,
            "QUESTMASTER_PATH_PREFIX": "/test/prefix",
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
        for key in ["PATH", "QUESTMASTER_APP", "QUESTMASTER_STATE_ROOT", "QUESTMASTER_BIN", "QUESTMASTER_PATH_PREFIX", "QUESTMASTER_DAEMON_SOCKET"] {
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
        try expect(state.settleDock(DockPanels()) == .unchanged, "hiding a non-focused dock should leave focus alone")
        try expect(!state.dockVisible, "dock should hide")
        try expect(state.focusedRegion == .tracker, "hiding a non-focused dock should keep the tracker focused")
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
        try expect(trackerShowsSkeleton(for: "connecting to backend..."), "current startup text should show skeleton")
        try expect(trackerShowsSkeleton(for: "backend not connected - retrying"), "retry text should keep showing the skeleton")
        try expect(trackerShowsSkeleton(for: "backend finishing a previous operation"), "handoff wait should show skeleton")
    }

    private static func testDockPanePublishesModeChanges() throws {
        let model = DockPaneModel()
        let snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        var publishCount = 0
        let cancellable = model.objectWillChange.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        let beforeChat = publishCount
        _ = model.apply(
            DockState(dockContent: .workerChat),
            snapshot: snapshot,
            preferredArtifactSessionID: nil
        )
        try expect(model.currentMode == .workerChat, "worker chat dock content should render worker chat mode")
        try expect(publishCount > beforeChat, "worker chat mode change should publish for DockRootView")

        let beforeArtifacts = publishCount
        _ = model.apply(
            DockState(dockContent: .artifactList),
            snapshot: snapshot,
            preferredArtifactSessionID: nil
        )
        try expect(model.currentMode == .artifacts, "artifact dock content should render artifact mode")
        try expect(publishCount > beforeArtifacts, "artifact mode change should publish for DockRootView")
    }

    /// The Version Control panel's keys: j/k and the arrows move the cursor, Return opens the row's page, y copies its URL
    /// and r asks the daemon to refresh; a click picks and opens; modified keys and others pass through.
    private static func testVersionControlDockKeysMoveOpenCopyAndRefresh() throws {
        let store = PullRequestStore()
        let session = TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", role: "master", pullRequestsRev: "1")
        guard let request = store.sync(selectedSessionID: "qm-a", sessions: [session], isVisible: true) else {
            throw TestFailure("a visible dock with a revision should pull")
        }
        func pull(_ number: Int, updated: String) throws -> PullRequestRow {
            let json = """
            {"key": "github.com/owner/repo#\(number)", "host": "github.com", "owner": "Owner", "repo": "Repo", "number": \(number),
             "watchers": [], "status": {"title": "T", "url": "https://github.com/owner/repo/pull/\(number)", "state": "open", "draft": false,
             "additions": 1, "deletions": 1, "comments": 0, "updated_at": "\(updated)", "stale": false}}
            """
            return try JSONDecoder().decode(PullRequestRow.self, from: Data(json.utf8))
        }
        _ = store.apply(response: [try pull(1, updated: "2026-10-01T00:00:00Z"), try pull(2, updated: "2026-10-02T00:00:00Z")], for: request)

        let pane = VersionControlDockPane(store: store)
        var effects: [PullRequestEffect] = []
        pane.onPullRequestEffect = { effects.append($0) }

        try expect(store.cursorKey?.hasSuffix("#2") == true, "the newest row starts under the cursor")
        try expect(pane.handleKeyDown(try keyEvent("j", keyCode: 38)), "j should be handled")
        try expect(store.cursorKey?.hasSuffix("#1") == true, "j should move down")
        try expect(pane.handleKeyDown(try keyEvent("k", keyCode: 40)), "k should be handled")
        try expect(store.cursorKey?.hasSuffix("#2") == true, "k should move up")
        try expect(pane.handleKeyDown(try keyEvent("\u{F701}", keyCode: 125)), "Down should be handled")
        try expect(store.cursorKey?.hasSuffix("#1") == true, "Down should move down")
        try expect(effects.isEmpty, "moving runs no effect")

        let url = URL(string: "https://github.com/owner/repo/pull/1")!
        try expect(pane.handleKeyDown(try keyEvent("\r", keyCode: 36)), "Return should be handled")
        try expect(effects.last == .open(url), "Return should open the row's page")
        try expect(pane.handleKeyDown(try keyEvent("y", keyCode: 16)), "y should be handled")
        try expect(effects.last == .copy(url), "y should copy the row's URL")
        try expect(pane.handleKeyDown(try keyEvent("r", keyCode: 15)), "r should be handled")
        guard case .refresh(let refresh)? = effects.last else {
            throw TestFailure("r should refresh, got \(String(describing: effects.last))")
        }
        try expect(refresh.sessionID == "qm-a", "r should refresh the selected session")

        pane.openPullRequest("github.com/owner/repo#2")
        try expect(store.cursorKey?.hasSuffix("#2") == true && effects.last == .open(URL(string: "https://github.com/owner/repo/pull/2")!), "a click should pick the row and open it")

        let count = effects.count
        try expect(!pane.handleKeyDown(try keyEvent("x", keyCode: 7)), "an unrelated key should pass through")
        try expect(!pane.handleKeyDown(try keyEvent("y", keyCode: 16, modifierFlags: [.command])), "a command chord should pass through")
        try expect(effects.count == count, "passed-through keys run no effect")
    }

    /// The refresh mark is the tracker's spinner, not a lookalike (one `SpinnerRing`): the same turn, once every
    /// `WorkingSpinner.period` and for good, only while its view is in a window, and still and full under Reduce Motion.
    private static func testRefreshSpinnerIsTheTrackersSpinnerAndTurnsOnlyInAWindow() throws {
        let window = HeadlessWindow(size: CGSize(width: 80, height: 80))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        window.contentView = container

        let spinner = SpinnerRingNSView(frame: NSRect(x: 0, y: 0, width: 15, height: 15))
        spinner.configure(stroke: 2, reduceMotion: false)
        try expect(spinner.spinAnimation == nil, "a spinner outside a window should not turn")
        container.addSubview(spinner)
        guard let turn = spinner.spinAnimation else {
            throw TestFailure("a spinner in a window should turn")
        }
        try expect(turn.duration == WorkingSpinner.period && turn.repeatCount == .infinity && !spinner.holdsStill, "it turns once every \(WorkingSpinner.period)s, for good")

        let status = TrackerPortraitStatusNSView(frame: NSRect(x: 40, y: 0, width: 40, height: 40))
        container.addSubview(status)
        status.configure(geometry: TrackerPlateDesign.collapsedCircleStatus, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        guard let trackerTurn = status.spinAnimation else {
            throw TestFailure("the tracker's working ring should turn")
        }
        try expect(
            turn.keyPath == trackerTurn.keyPath && turn.fromValue as? Double == trackerTurn.fromValue as? Double
                && turn.toValue as? Double == trackerTurn.toValue as? Double && turn.duration == trackerTurn.duration
                && turn.repeatCount == trackerTurn.repeatCount,
            "it is the tracker's turn: same axis, direction and period"
        )

        spinner.configure(stroke: 2, reduceMotion: true)
        try expect(spinner.spinAnimation == nil && spinner.holdsStill, "Reduce Motion holds the ring still and full")
        spinner.configure(stroke: 2, reduceMotion: false)
        try expect(spinner.spinAnimation != nil && !spinner.holdsStill, "and it turns again when the setting goes")

        spinner.removeFromSuperview()
        try expect(spinner.spinAnimation == nil, "a spinner that leaves its window stops")
    }

    /// The Version Control title bar shows the spinner beside its title exactly while the pull request store refreshes
    /// (`r` until the daemon's reply and one turn), and the other docks never do. It reads the ring's presence, not its
    /// animation: a hosted ring turns or holds still by the host's Reduce Motion setting (`SpinnerRingView` reads the
    /// environment's), which a CI runner doesn't share with a desk, so the turn is tested on the view itself
    /// (`testRefreshSpinnerIsTheTrackersSpinnerAndTurnsOnlyInAWindow`). Every wait lays the hosted views out, as the
    /// other hosted-view tests do: nothing else is guaranteed to on a host with no display ticking.
    private static func testVersionControlTitleBarShowsTheSpinnerWhileTheStoreRefreshes() throws {
        let store = PullRequestStore()
        let session = TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", role: "master", pullRequestsRev: "1")
        _ = store.sync(selectedSessionID: "qm-a", sessions: [session], isVisible: true)
        let window = HeadlessWindow(size: CGSize(width: 480, height: 300))
        let top = DockShellView(body: NSView(), model: DockChromeModel(topBar: .versionControl, isRefreshing: { store.isRefreshing }))
        let bottom = DockShellView(body: NSView(), model: DockChromeModel(isRefreshing: { false }))
        let column = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 300))
        top.frame = NSRect(x: 0, y: 150, width: 480, height: 150)
        bottom.frame = NSRect(x: 0, y: 0, width: 480, height: 150)
        column.addSubview(top)
        column.addSubview(bottom)
        window.contentView = column
        window.show()
        defer { window.close() }
        func spinner(in shell: DockShellView) -> SpinnerRingNSView? {
            column.layoutSubtreeIfNeeded()
            return descendant(SpinnerRingNSView.self, in: shell)
        }

        try waitForMainQueue("the title bar to draw") {
            column.layoutSubtreeIfNeeded()
            return descendant(NSHostingView<DockTopBar>.self, in: top) != nil
        }
        try expect(spinner(in: top) == nil, "no spinner until a refresh starts")

        let now = Date()
        guard case .refresh(let request)? = store.handle(.refresh, now: now) else {
            throw TestFailure("r should ask for a refresh")
        }
        // What the host does, for the CI log: whether the ring mounts with nothing laying the views out, and whether the
        // host holds it still.
        var mountedWithoutLayout = false
        let looked = Date()
        while Date().timeIntervalSince(looked) < 1, !mountedWithoutLayout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            mountedWithoutLayout = descendant(SpinnerRingNSView.self, in: top) != nil
        }
        try waitForMainQueue("the spinner to appear") { spinner(in: top) != nil }
        let ring = spinner(in: top)
        print("note: host Reduce Motion \(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), hosted ring holds still \(ring?.holdsStill == true), turning \(ring?.spinAnimation != nil), mounted without a forced layout \(mountedWithoutLayout)")
        try expect(spinner(in: bottom) == nil, "the bottom panel's bar never shows it")

        store.finishRefresh(request, failed: false, now: now.addingTimeInterval(PullRequestStore.refreshMinimumShown + 1))
        try waitForMainQueue("the spinner to go") { spinner(in: top) == nil }
    }

    /// The column puts Version Control on top at 300, the bottom panel under it, 20 apart; a panel alone fills the column and
    /// a hidden one leaves the view hidden.
    private static func testDockColumnLaysOutItsPanels() throws {
        let top = DockShellView(body: NSView(), model: DockChromeModel(topBar: .versionControl))
        let bottom = DockShellView(body: NSView())
        let column = DockColumnView(top: top, bottom: bottom)
        column.frame = NSRect(x: 0, y: 0, width: 480, height: 860)
        func laidOut(_ panels: DockPanels) -> DockColumnView {
            column.setPanels(panels)
            column.layoutSubtreeIfNeeded()
            return column
        }

        _ = laidOut(DockPanels(top: true, bottom: true))
        try expect(!top.isHidden && !bottom.isHidden, "both panels show in the split")
        try expect(top.frame == NSRect(x: 0, y: 560, width: 480, height: 300), "Version Control sits at the column's top, 300 tall, got \(top.frame)")
        try expect(bottom.frame == NSRect(x: 0, y: 0, width: 480, height: 540), "the bottom panel takes what's left under a 20 gap, got \(bottom.frame)")

        _ = laidOut(DockPanels(top: true))
        try expect(!top.isHidden && bottom.isHidden, "Version Control alone leaves the bottom panel hidden")
        try expect(top.frame == NSRect(x: 0, y: 0, width: 480, height: 860), "Version Control alone fills the dock, got \(top.frame)")

        _ = laidOut(DockPanels(bottom: true))
        try expect(top.isHidden && !bottom.isHidden, "the bottom panel alone leaves Version Control hidden")
        try expect(bottom.frame == NSRect(x: 0, y: 0, width: 480, height: 860), "the bottom panel alone fills the dock, got \(bottom.frame)")

        _ = laidOut(DockPanels(top: true, bottom: true))
        try expect(top.frame.height == 300 && bottom.frame.height == 540, "the split comes back as it was")
    }

    /// The terminal consumes command-key chords as key equivalents before the menu sees them, so the chords that must work
    /// from it (⇧⌘H/L, ⇧⌘R) run from `MenuController`'s key monitor, which comes first; ⇧⌘K/J do too, but only in the
    /// dock's scope (⇧⌘J is also Ghostty's own write_screen_file:paste, shadowed only there), and the monitor returns them
    /// untouched elsewhere. A stand-in for the terminal consumes every key equivalent; an in-process key event for each
    /// chord must reach its action once, never the stand-in (so the menu can't run it a second time), and a held key must
    /// not run it again.
    private static func testCommandKeysReachTheirActionsWhileTheTerminalConsumesKeyEquivalents() throws {
        final class TerminalStandIn: NSView {
            var keyEquivalents = 0
            var keyDowns = 0
            override var acceptsFirstResponder: Bool { true }
            override func performKeyEquivalent(with event: NSEvent) -> Bool {
                keyEquivalents += 1
                return true
            }
            override func keyDown(with event: NSEvent) { keyDowns += 1 }
        }
        let window = HeadlessWindow(size: CGSize(width: 400, height: 300))
        let terminal = TerminalStandIn(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = terminal
        window.show(key: true)
        defer { window.close() }
        try expect(window.makeFirstResponder(terminal), "the stand-in terminal should take the keys")

        func send(_ characters: String, _ plain: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags, isARepeat: Bool = false) throws {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: plain,
                isARepeat: isARepeat, keyCode: keyCode
            ) else {
                throw TestFailure("could not create the \(plain) key event")
            }
            NSApp.sendEvent(event)
        }
        // keyCodes: K 40, J 38, H 4, L 37, R 15. Shift gives the capital character.
        let chords: [(name: String, characters: String, plain: String, keyCode: UInt16, flags: NSEvent.ModifierFlags)] = [
            ("⇧⌘K", "K", "K", 40, [.command, .shift]),
            ("⇧⌘J", "J", "J", 38, [.command, .shift]),
            ("⇧⌘R", "R", "R", 15, [.command, .shift]),
            ("⇧⌘H", "H", "H", 4, [.command, .shift]),
            ("⇧⌘L", "L", "L", 37, [.command, .shift]),
        ]

        // The premise: the view hierarchy sees a key equivalent before the menu, and the terminal consumes it, so a menu item
        // alone never runs from the terminal.
        let first = chords[0]
        guard let premise = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: first.flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: first.characters, charactersIgnoringModifiers: first.plain,
            isARepeat: false, keyCode: first.keyCode
        ) else {
            throw TestFailure("could not create the premise event")
        }
        try expect(window.performKeyEquivalent(with: premise) && terminal.keyEquivalents == 1, "the terminal consumes the chord as a key equivalent, ahead of the menu")
        terminal.keyEquivalents = 0

        var ran: [String] = []
        // The dock's chords are in scope only while it has the keys (`NavigationStore.dockPanelKeyRoute`).
        var dockHasKeys = true
        let actions = CommandKeyActions(
            focusRegionLeft: .anywhere { ran.append("⇧⌘H") },
            focusRegionRight: .anywhere { ran.append("⇧⌘L") },
            focusDockTop: CommandKeyAction(handles: { dockHasKeys }, run: { ran.append("⇧⌘K") }),
            focusDockBottom: CommandKeyAction(handles: { dockHasKeys }, run: { ran.append("⇧⌘J") }),
            toggleVersionControlDock: .anywhere { ran.append("⇧⌘R") }
        )
        let menu = MenuController()
        menu.installCommandKeyMonitor(actions)
        defer { menu.stop() }

        // Through the real monitor: NSApp runs it ahead of any view, so each chord reaches its action exactly once.
        for chord in chords {
            try send(chord.characters, chord.plain, keyCode: chord.keyCode, chord.flags)
        }
        try expect(ran == chords.map(\.name), "each chord should run its own action once, in order, got \(ran)")
        try expect(terminal.keyEquivalents == 0 && terminal.keyDowns == 0, "and none should reach the terminal, so the menu can't run it again")

        // What the monitor hands back decides whether the terminal or the menu ever sees the press: nil for a chord it took,
        // the event itself for anything else.
        let handler = MenuController.commandKeyHandler(actions)
        ran.removeAll()
        for chord in chords {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: chord.flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chord.characters, charactersIgnoringModifiers: chord.plain,
                isARepeat: false, keyCode: chord.keyCode
            ) else {
                throw TestFailure("could not create the \(chord.name) event")
            }
            try expect(handler(event) == nil, "the monitor should swallow \(chord.name) once it has run it")
        }
        try expect(ran == chords.map(\.name), "and run it, got \(ran)")

        ran.removeAll()
        try send("K", "K", keyCode: 40, [.command, .shift], isARepeat: true)
        try expect(ran.isEmpty, "a held chord is swallowed without running again")
        try send("K", "K", keyCode: 40, [.command, .shift, .capsLock])
        try expect(ran == ["⇧⌘K"], "Caps Lock doesn't change a chord, got \(ran)")

        // Out of the dock's scope (the terminal or tracker focused, a modal up, a dock with one panel) the dock's chords
        // are returned untouched, so the terminal still gets ⇧⌘K and Ghostty's own ⇧⌘J; the global chords stay the monitor's.
        ran.removeAll()
        dockHasKeys = false
        for chord in chords {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: chord.flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chord.characters, charactersIgnoringModifiers: chord.plain,
                isARepeat: false, keyCode: chord.keyCode
            ) else {
                throw TestFailure("could not create the \(chord.name) event")
            }
            let result = handler(event)
            if chord.name == "⇧⌘K" || chord.name == "⇧⌘J" {
                try expect(result === event, "\(chord.name) outside the dock goes on to the terminal, not taken")
            } else {
                try expect(result == nil, "\(chord.name) works from every region")
            }
        }
        try expect(ran == ["⇧⌘R", "⇧⌘H", "⇧⌘L"], "only the global chords ran outside the dock, got \(ran)")
        ran.removeAll()
        try send("K", "K", keyCode: 40, [.command, .shift], isARepeat: true)
        try expect(ran.isEmpty, "a held dock chord outside the dock runs nothing either")
        dockHasKeys = true

        ran.removeAll()
        for (characters, plain, keyCode, flags) in [("˚", "k", UInt16(40), NSEvent.ModifierFlags([.command, .option])), ("K", "K", UInt16(40), NSEvent.ModifierFlags([.command, .option, .shift])), ("k", "k", UInt16(40), []), ("r", "r", UInt16(15), [.command])] {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: plain,
                isARepeat: false, keyCode: keyCode
            ) else {
                throw TestFailure("could not create the \(plain) event")
            }
            try expect(handler(event) === event, "a key that is no chord of the monitor's goes on to the terminal and the menu")
        }
        try expect(ran.isEmpty, "and runs nothing")
    }

    /// A panel appearing or going away while the dock stays up is one short transition that ends on its own: the panel
    /// starts unseen and slid out, everything lands on the final layout, and nothing keeps running. The first panel
    /// showing, a hidden window and Reduce Motion skip it.
    private static func testDockPanelsTransitionOnceAndSkipItWithReducedMotion() throws {
        func makeColumn() -> (DockColumnView, DockShellView, DockShellView, HeadlessWindow) {
            let window = HeadlessWindow(size: CGSize(width: 1000, height: 900))
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
            let top = DockShellView(body: NSView(), model: DockChromeModel(topBar: .versionControl))
            let bottom = DockShellView(body: NSView())
            let column = DockColumnView(top: top, bottom: bottom)
            column.frame = NSRect(x: 500, y: 0, width: 480, height: 860)
            column.reducesMotion = { false }
            content.addSubview(column)
            window.contentView = content
            window.show()
            return (column, top, bottom, window)
        }
        func settle(_ seconds: TimeInterval = DockPanelMotion.duration + 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

        let (column, top, bottom, window) = makeColumn()
        defer { window.close() }
        column.setPanels(DockPanels(bottom: true), animated: true)
        try expect(!column.isTransitioning, "the dock's first panel showing is the split view's to animate, not the column's")
        column.layoutSubtreeIfNeeded()
        try expect(bottom.frame.height == 860 && bottom.alphaValue == 1, "the first panel lands at once, fully shown")

        column.setPanels(DockPanels(top: true, bottom: true), animated: true)
        try expect(column.isTransitioning, "a panel appearing while the dock stays up transitions")
        try expect(!top.isHidden && top.alphaValue == 0, "the new panel starts unseen, got alpha \(top.alphaValue)")
        try expect(top.frame.maxY == 870 && top.frame.height == 300, "and 10 above its slot, got \(top.frame)")
        settle(DockPanelMotion.duration / 2)
        try expect(column.isTransitioning && top.alphaValue > 0 && top.alphaValue < 1, "partway it's half in, got alpha \(top.alphaValue)")
        settle()
        try expect(!column.isTransitioning, "the transition ends on its own")
        try expect(top.alphaValue == 1 && top.frame == NSRect(x: 0, y: 560, width: 480, height: 300), "Version Control ends at its slot, got \(top.frame)")
        try expect(bottom.alphaValue == 1 && bottom.frame == NSRect(x: 0, y: 0, width: 480, height: 540), "the bottom panel ends shrunk under it, got \(bottom.frame)")

        column.setPanels(DockPanels(bottom: true), animated: true)
        try expect(column.isTransitioning && !top.isHidden, "a panel going away stays up while it fades")
        settle()
        try expect(!column.isTransitioning && top.isHidden, "then it's gone")
        try expect(bottom.frame == NSRect(x: 0, y: 0, width: 480, height: 860) && bottom.alphaValue == 1, "and the bottom panel fills the dock again, got \(bottom.frame)")

        // A new change mid-transition settles the running one first.
        column.setPanels(DockPanels(top: true, bottom: true), animated: true)
        settle(DockPanelMotion.duration / 3)
        column.setPanels(DockPanels(top: true), animated: true)
        try expect(column.isTransitioning, "the interrupting change starts its own transition")
        settle()
        try expect(!column.isTransitioning && bottom.isHidden && top.frame == NSRect(x: 0, y: 0, width: 480, height: 860) && top.alphaValue == 1, "and the dock ends on its latest panels, got \(top.frame)")

        let (still, stillTop, stillBottom, stillWindow) = makeColumn()
        defer { stillWindow.close() }
        still.reducesMotion = { true }
        still.setPanels(DockPanels(bottom: true))
        still.setPanels(DockPanels(top: true, bottom: true), animated: true)
        try expect(!still.isTransitioning, "Reduce Motion skips the transition")
        still.layoutSubtreeIfNeeded()
        try expect(stillTop.alphaValue == 1 && stillTop.frame == NSRect(x: 0, y: 560, width: 480, height: 300) && stillBottom.frame.height == 540, "and the panels land at once, got \(stillTop.frame)")
    }

    /// Focus goes to one dock panel at a time: its pane takes the first responder and only its frame lifts, and moving to the
    /// other panel hands both over.
    private static func testOnlyTheFocusedDockPanelHasTheKeys() throws {
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 900))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        let pane = VersionControlDockPane(store: PullRequestStore())
        let bottomPane = SwiftUIDockPane(
            store: RuntimeStore(sourceLabel: "test"),
            workerChatStore: WorkerChatStore(),
            newQuestPresenter: NewQuestSheetPresenter(),
            settingsPresenter: SettingsSheetPresenter()
        )
        let top = DockShellView(body: pane, model: DockChromeModel(topBar: .versionControl))
        let bottom = DockShellView(body: bottomPane)
        let column = DockColumnView(top: top, bottom: bottom)
        column.frame = NSRect(x: 500, y: 0, width: 480, height: 860)
        content.addSubview(column)
        window.contentView = content
        let navigation = NavigationStore()
        let coordinator = ShellFocusCoordinator(
            navigation: navigation,
            window: { window },
            splitView: { nil },
            terminalShell: { nil },
            topDockShell: { top },
            bottomDockShell: { bottom },
            dockColumn: { column },
            dockPanels: { DockPanels(top: true, bottom: true) },
            footerShell: { nil },
            trackerHosting: { nil },
            dockView: { bottomPane },
            versionControlPane: { pane },
            terminalHost: { nil },
            modalHost: { nil },
            updateDockTabs: {}
        )
        window.show(key: true)
        defer { window.close() }

        coordinator.focusDockPanel(.top)
        try expect(window.firstResponder === pane, "the top panel's pane should take the keys")
        try expect(top.isFocused && !bottom.isFocused, "only the top panel's frame should lift")
        try expect(pane.hasFocusedLook && !bottomPane.isFocused, "Version Control draws its cursor, and the bottom panel's content its focused look, only for the panel with the keys")
        coordinator.focusDockPanel(.bottom)
        try expect(!top.isFocused && bottom.isFocused, "the bottom panel's frame lifts as the top's drops")
        try expect(!pane.hasFocusedLook && bottomPane.isFocused, "the cursor hides with the top panel's keys and the bottom content's focused look comes on")
        coordinator.focusDockPanel(.top)
        coordinator.focus(.tracker)
        try expect(!top.isFocused && !bottom.isFocused, "no panel has the keys once focus leaves the dock")
        try expect(!pane.hasFocusedLook && !bottomPane.isFocused, "nothing in the dock draws a focused look once focus leaves it")
        coordinator.focus(.dock)
        try expect(top.isFocused && !bottom.isFocused && window.firstResponder === pane, "coming back lands on the panel that had the keys")
        try expect(pane.hasFocusedLook && !bottomPane.isFocused, "and its cursor shows again")
    }

    private static func testDockSelectionPublishesImmediately() throws {
        let first = ArtifactReference(kind: "html", path: "/tmp/first.html", label: "First", sessionID: "qm-a", addedAt: "")
        let second = ArtifactReference(kind: "html", path: "/tmp/second.html", label: "Second", sessionID: "qm-a", addedAt: "")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(
            repos: [TrackerRepo(id: "repo-a", name: "Alpha", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", workerCount: 0, artifacts: [first, second]),
            ])]
        )

        let coordinator = DockCoordinator()
        let model = DockPaneModel()
        model.onSelectedArtifactChange = { coordinator.state.selectedArtifactID = $0 }

        _ = model.apply(
            DockState(dockContent: .artifactList, selectedArtifactID: first.id),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.handleKeyDown(try keyEvent("j", keyCode: 38), snapshot: snapshot), "j should select the next artifact")
        try expect(coordinator.state.selectedArtifactID == second.id, "artifact selection should persist before the next render")

        _ = model.apply(
            coordinator.state,
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.artifactModel.selectedArtifactID == second.id, "render should retain the selected artifact")
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

    private static func testArtifactListGChordJumpsToEdgesAndForcesRescroll() throws {
        let first = ArtifactReference(kind: "html", path: "/tmp/first.html", label: "First", sessionID: "qm-a", addedAt: "")
        let second = ArtifactReference(kind: "html", path: "/tmp/second.html", label: "Second", sessionID: "qm-a", addedAt: "")
        let third = ArtifactReference(kind: "html", path: "/tmp/third.html", label: "Third", sessionID: "qm-a", addedAt: "")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "repo-a", name: "Alpha", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", workerCount: 0, artifacts: [first, second, third]),
            ]),
        ])

        let model = DockPaneModel()
        _ = model.apply(
            DockState(dockContent: .artifactList, selectedArtifactID: first.id),
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
        let artifacts = ["a", "b", "c"].map {
            ArtifactReference(kind: "html", path: "/tmp/\($0).html", label: $0, sessionID: "qm-a", addedAt: "")
        }
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "repo-a", name: "Alpha", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", workerCount: 0, artifacts: artifacts),
            ]),
        ])
        let g = try keyEvent("g", keyCode: 5)
        let shiftG = try keyEvent("G", keyCode: 5, modifierFlags: [.shift])
        func listModel() -> DockPaneModel {
            let model = DockPaneModel()
            _ = model.apply(
                DockState(dockContent: .artifactList, selectedArtifactID: artifacts[1].id),
                snapshot: snapshot,
                preferredArtifactSessionID: "qm-a"
            )
            return model
        }

        let afterG = listModel()
        let last = afterG.artifactModel.artifacts.last?.id
        try expect(afterG.handleKeyDown(g, snapshot: snapshot), "g should arm the chord")
        try expect(afterG.handleKeyDown(shiftG, snapshot: snapshot), "G should jump to the last artifact, not continue the chord")
        try expect(afterG.artifactModel.selectedArtifactID == last, "G should select the last artifact")
        try expect(afterG.handleKeyDown(g, snapshot: snapshot), "g right after G should re-arm rather than resolve")
        try expect(afterG.artifactModel.selectedArtifactID == last, "a freshly re-armed g alone should not move the selection")

        let afterOtherKey = listModel()
        let selected = afterOtherKey.artifactModel.selectedArtifactID
        try expect(afterOtherKey.handleKeyDown(g, snapshot: snapshot), "g should arm the chord")
        _ = afterOtherKey.handleKeyDown(try keyEvent("x", keyCode: 7), snapshot: snapshot)
        try expect(afterOtherKey.handleKeyDown(g, snapshot: snapshot), "g after an unrelated key should re-arm rather than resolve")
        try expect(afterOtherKey.artifactModel.selectedArtifactID == selected, "a freshly re-armed g alone should not move the selection")
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
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, artifacts: [artifact]),
            ]),
        ])

        let model = DockPaneModel()
        var copied = false
        model.onCopyArtifactPath = { copied = true }
        _ = model.apply(
            DockState(dockContent: .artifactList, selectedArtifactID: artifact.id),
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
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, artifacts: [artifact, secondArtifact]),
            ]),
        ])
        let model = DockPaneModel()
        _ = model.apply(
            DockState(dockContent: .artifactList, selectedArtifactID: artifact.id),
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
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, artifacts: [artifact, secondArtifact]),
            ]),
        ])
        let model = DockPaneModel()
        var deleted: [ArtifactReference] = []
        model.onDeleteArtifacts = { deleted = $0 }
        _ = model.apply(
            DockState(dockContent: .artifactList, selectedArtifactID: artifact.id),
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
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, artifacts: [artifact]),
            ]),
        ])

        let model = DockPaneModel()
        var backCount = 0
        model.onShowArtifactListIntent = { backCount += 1 }
        _ = model.apply(
            DockState(dockContent: .artifactViewer, selectedArtifactID: artifact.id),
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
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha Repo", workerCount: 0, artifacts: [artifact]),
            ]),
        ])

        let model = DockPaneModel()
        var copied = false
        model.onCopyArtifactPath = { copied = true }
        _ = model.apply(
            DockState(dockContent: .artifactViewer, selectedArtifactID: artifact.id),
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

    private static func testDockContentRoutingRequiresASession() throws {
        try expect(!DockContentRouting.canShow(.artifactList, sessionID: nil), "artifact list should require a current session")
        try expect(!DockContentRouting.canShow(.artifactList, sessionID: "   "), "artifact list should require a session id")
        try expect(!DockContentRouting.canShow(.artifactViewer, sessionID: ""), "artifact viewer should still require a current session")
        try expect(DockContentRouting.canShow(.artifactList, sessionID: "qm-demo"), "artifact list should open with a current session")
        try expect(DockContentRouting.canShow(.workerChat, sessionID: "qm-demo"), "worker chat should open for every attached session")
        try expect(!DockContentRouting.canShow(.workerChat, sessionID: nil), "worker chat should still require a current session")
    }

    private static func testArtifactDockCommandSwitchesFromWorkerChat() throws {
        try expect(
            !DockCommandRouting.shouldHideArtifactDock(isDockVisible: false, content: .artifactList),
            "Cmd-3 should show artifacts when the dock is hidden"
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

    /// A system sheet would attach its own window (with an opaque, rounded panel behind the scooped corners);
    /// an in-window modal must not, and its host must cover the window only while something is presented.
    private static func testModalsPresentInsideTheWindowNotAsSystemSheets() throws {
        struct Item: Identifiable { let id: String }
        final class Holder: ObservableObject { @Published var item: Item? }
        struct Presenting: View {
            @ObservedObject var holder: Holder
            let stack: InWindowModalStack
            var body: some View {
                Color.clear
                    .inWindowSheet(item: $holder.item) { _ in Color.clear.frame(width: 120, height: 80).scoopedPanel() }
                    .environment(\.inWindowModalStack, stack)
            }
        }
        let stack = InWindowModalStack()
        let holder = Holder()
        let window = HeadlessWindow(size: CGSize(width: 400, height: 300))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let presenting = NSHostingView(rootView: Presenting(holder: holder, stack: stack))
        presenting.frame = content.bounds
        let host = InWindowModalHost(stack: stack)
        content.addSubview(presenting)
        // Pinned with Auto Layout, as ShellRootContainerView.addOverlay pins it in the app.
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        let windowSize = window.frame.size
        window.show()
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        settle()
        try expect(host.isHidden, "the modal host should stay hidden, and out of the way of clicks, while nothing is presented")

        holder.item = Item(id: "a")
        settle()
        try expect(window.attachedSheet == nil, "presenting should not attach a system sheet window")
        try expect(stack.entries.count == 1, "presenting should push one in-window modal, got \(stack.entries.count)")
        try expect(!host.isHidden, "the modal host should show while a modal is presented")
        try expect(window.firstResponder === host, "the modal host should take the keys from whatever had them")
        try expect(window.frame.size == windowSize, "a presented modal must not resize the window, got \(window.frame.size) from \(windowSize)")

        holder.item = nil
        RunLoop.main.run(until: Date().addingTimeInterval(ModalFade.fadeOut / 3))
        try expect(stack.isEmpty, "a dismissed modal should stop counting as open at once, so keys go back underneath")
        try expect(stack.entries.count == 1 && stack.entries[0].closing, "a dismissed modal should stay mounted, closing, while it fades out")
        try expect(!host.isHidden, "the host should stay visible until the fade-out ends")
        settle()
        try expect(stack.entries.isEmpty && host.isHidden, "once the fade-out ends the stack should empty and the host hide")
    }

    /// The Quest Log is one entry on the same stack as every modal: what opens over it draws over it, Esc
    /// closes the top modal only, global commands don't stack an unrelated modal over it (⌘T opens New Quest
    /// as its child), and once the last modal has faded out focus is back where it was before the first.
    private static func testModalStackClosesTheTopModalFirstAndRestoresFocus() throws {
        struct Item: Identifiable { let id: String }
        final class Holder: ObservableObject { @Published var item: Item? }
        final class StandInTerminal: NSView { override var acceptsFirstResponder: Bool { true } }
        struct Presenting: View {
            @ObservedObject var newSession: NewSessionSheetPresenter
            @ObservedObject var newQuest: Holder
            let stack: InWindowModalStack
            var body: some View {
                Color.clear
                    .inWindowSheet(item: $newSession.presentation) { NewSessionSheetView(presentation: $0, dismiss: { newSession.dismiss() }) }
                    .inWindowSheet(item: $newQuest.item) { _ in
                        Color.clear.frame(width: 120, height: 80).scoopedPanel()
                            .background(SheetKeyEventMonitor { event in
                                guard event.keyCode == 53 else {
                                    return false
                                }
                                newQuest.item = nil
                                return true
                            })
                    }
                    .environment(\.inWindowModalStack, stack)
            }
        }
        let stack = InWindowModalStack()
        let newSession = NewSessionSheetPresenter()
        let newQuest = Holder()
        let store = QuestLogStore()
        store.sync(quests: [QuestItem(id: "q", content: "A quest", projectID: "p", projectName: "p")], repos: [])
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 860))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 860))
        let terminal = StandInTerminal(frame: content.bounds)
        let presenting = NSHostingView(rootView: Presenting(newSession: newSession, newQuest: newQuest, stack: stack))
        presenting.frame = content.bounds
        let host = InWindowModalHost(stack: stack)
        var fallbackFocusCount = 0
        host.onEmpty = { fallbackFocusCount += 1 }
        content.addSubview(terminal)
        content.addSubview(presenting)
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        let windowSize = window.frame.size
        window.show(key: true)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        func pressEsc() {
            guard let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
                return
            }
            NSApp.sendEvent(esc)
            settle()
        }
        window.makeFirstResponder(terminal)
        settle()

        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: QuestLogFilter(), pageScroll: QuestLogPageScroll(), onCommand: { command in
            guard command == .close else {
                return
            }
            store.close()
            stack.dismiss(id: QuestLogModal.stackID)
        }))
        settle()
        try expect(stack.top?.kind == .questLog, "the Quest Log should be an entry on the modal stack")
        try expect(window.firstResponder === host, "the open Quest Log should hold the keys, not the terminal")
        try expect(stack.route(.newSession) == .ignored && stack.route(.settings) == .ignored, "a global New Session or Settings over the Quest Log should be ignored")
        try expect(stack.route(.toggleQuestLog) == .allowed, "the Quest Log's toggle should act on it while it's on top")

        // Send forth's New Session: a child the log opens itself goes on top, and Esc closes it first.
        newSession.present(initialPath: "/tmp", mutationClient: StubMutationClient(result: .failure(TestFailure("unused"))), directoryClient: nil, onSuccess: { _ in })
        settle()
        try expect(stack.entries.count == 2 && stack.entries.last?.kind == .other, "the child should draw on top of the Quest Log, got \(stack.entries.map(\.kind))")
        try expect(stack.route(.toggleQuestLog) == .ignored, "the Quest Log's toggle should do nothing while a child is on top")
        pressEsc()
        try expect(newSession.presentation == nil, "the first Esc should close the child on top")
        try expect(store.isOpen && stack.top?.kind == .questLog, "the first Esc should leave the Quest Log open")

        // ⌘T over the log: New Quest opens as its child, and Esc closes it alone.
        try expect(stack.route(.newQuest) == .child, "⌘T over the Quest Log should open New Quest as its child")
        newQuest.item = Item(id: "new-quest")
        settle()
        try expect(stack.entries.last?.kind == .other && stack.entries.filter { !$0.closing }.count == 2, "New Quest should open on top of the Quest Log")
        pressEsc()
        try expect(newQuest.item == nil && store.isOpen, "Esc should close New Quest and leave the Quest Log open")

        pressEsc()
        try expect(!store.isOpen, "the next Esc should close the Quest Log")
        try expect(stack.entries.isEmpty && host.isHidden, "once every modal has faded out the host should hide")
        try expect(window.firstResponder === terminal, "focus should go back to the terminal, got \(String(describing: window.firstResponder))")
        try expect(fallbackFocusCount == 0, "with the terminal still there the fallback shouldn't run")
        try expect(window.frame.size == windowSize, "modals must not resize the window, got \(window.frame.size) from \(windowSize)")
    }

    /// New Session → Summon with the real sheet: the success path closes the sheet and switches to the new session,
    /// whose focusTerminal waits under the fading sheet. Once the fade ends focus lands on the terminal, and no view
    /// of the closing sheet takes focus at any point after Summon: not the prompt editor that held it at submit, nor
    /// an agent-tab focus sink. The user's trace (2026-10-22) had the editor take focus during the fade and again 3ms
    /// after the restore, each time from a sheet update that ran after the host or the terminal had focus, leaving
    /// the window with none. Dismissing straight through the stack puts close()'s own update (it clears the path
    /// suggestions) after the host takes focus, which makes that ordering deterministic here.
    private static func testSummonLeavesFocusOnTheNewTerminal() throws {
        final class StandIn: NSView { override var acceptsFirstResponder: Bool { true } }
        final class StandInTerminalHost: TerminalPaneHosting {
            let view: NSView = StandIn(frame: NSRect(x: 600, y: 0, width: 400, height: 700))
            var tmuxSessionID: String? { nil }
            var onFocusRequested: (() -> Void)?
            var onDetach: (() -> Void)?
            let cellMetrics: TerminalCellMetrics = .unavailable
            var onCellMetricsChanged: (() -> Void)?
            func start() {}
            func stop() {}
            func focus(in window: NSWindow?) { window?.makeFirstResponder(view) }
            func connect(to config: TerminalLaunchConfig) throws {}
        }
        for start in [NewSessionField.prompt, .agent] {
            let stack = InWindowModalStack()
            let window = HeadlessWindow(size: CGSize(width: 1000, height: 700))
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            let tracker = StandIn(frame: NSRect(x: 0, y: 0, width: 300, height: 700))
            let terminal = StandInTerminalHost()
            let host = InWindowModalHost(stack: stack)
            content.addSubview(tracker)
            content.addSubview(terminal.view)
            host.frame = content.bounds
            content.addSubview(host)
            window.contentView = content
            let navigation = NavigationStore()
            let coordinator = ShellFocusCoordinator(
                navigation: navigation,
                window: { window },
                splitView: { nil },
                terminalShell: { nil },
                topDockShell: { nil },
                bottomDockShell: { nil },
                dockColumn: { nil },
                dockPanels: { DockPanels() },
                footerShell: { nil },
                trackerHosting: { tracker },
                dockView: { nil },
                versionControlPane: { nil },
                terminalHost: { terminal },
                modalHost: { host },
                updateDockTabs: {}
            )
            host.onEmpty = { coordinator.focusCurrentRegion() }
            window.show(key: true)
            defer { window.close() }
            func settle(_ seconds: TimeInterval = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            var responders: [NSResponder?] = []
            let observation = window.observe(\.firstResponder, options: [.new]) { window, _ in
                MainActor.assumeIsolated { responders.append(window.firstResponder) }
            }
            defer { observation.invalidate() }

            coordinator.focus(.terminal)
            settle()
            let id = UUID()
            var summoned: String?
            let presentation = NewSessionSheetPresentation(
                initialPath: NSTemporaryDirectory(),
                initialTitle: "",
                initialPrompt: "",
                initialFocus: start,
                mutationClient: StubMutationClient(result: .success(ServeMutationAck(data: ["session_id": "qm-new"]))),
                directoryClient: nil,
                modelClient: nil,
                effortClient: nil,
                onSuccess: { sessionID in
                    summoned = sessionID
                    coordinator.focusTerminal()
                }
            )
            stack.present(id: id, AnyView(NewSessionSheetView(presentation: presentation, dismiss: { stack.dismiss(id: id) })))
            settle()
            let holder = String(describing: window.firstResponder.map { type(of: $0) })
            let expected = start == .prompt ? "ModalPromptEditorTextView" : "SinkView"
            try expect(holder.contains(expected), "\(start): the sheet should start with \(expected) focused, got \(holder)")

            // ⌘Return, through the sheet's own key handler, as the user summons.
            guard let monitor = subviews(of: host).compactMap({ $0 as? SheetKeyEventMonitor.MonitorView }).first else {
                throw TestFailure("\(start): the sheet's key monitor never mounted")
            }
            let submitted = responders.count
            _ = monitor.onKeyDown(try keyEvent("\r", keyCode: 36, modifierFlags: .command))
            settle(0.6)
            for _ in 0..<5 {
                settle(0.05)
            }
            try expect(summoned == "qm-new", "\(start): Summon should succeed, got \(String(describing: summoned))")
            try expect(stack.entries.isEmpty && host.isHidden, "\(start): the sheet should be gone")
            try expect(window.firstResponder === terminal.view, "\(start): focus should end on the new terminal, got \(String(describing: window.firstResponder))")
            let sinceSubmit = responders[submitted...]
            let neutral: (NSResponder?) -> Bool = { $0 == nil || $0 === host || $0 === window || $0 === terminal.view }
            let taken = sinceSubmit.filter { !neutral($0) }.map { $0.map { String(describing: type(of: $0)) } ?? "nil" }
            try expect(taken.isEmpty, "\(start): no view of the closing sheet should take focus after Summon, got \(taken)")
            // From the restore on, focus never leaves the terminal.
            guard let landed = sinceSubmit.firstIndex(where: { $0 === terminal.view }) else {
                throw TestFailure("\(start): focus never reached the terminal after Summon")
            }
            let after = responders[landed...].filter { $0 !== terminal.view }
            try expect(after.isEmpty, "\(start): nothing should take focus after the terminal, got \(after.map { $0.map { String(describing: type(of: $0)) } ?? "nil" })")
        }
    }

    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(subviews(of:))
    }

    /// Every shell focus request (the terminal, a region, a session switch's focusTerminal) goes through
    /// `ShellFocusCoordinator.focusCurrentRegion`. Under a modal it moves only the navigation state: the keys
    /// stay on the modal, and focus lands on the requested region once the last modal has faded out.
    private static func testShellFocusRequestsWaitForTheModals() throws {
        final class StandIn: NSView { override var acceptsFirstResponder: Bool { true } }
        final class StandInTerminalHost: TerminalPaneHosting {
            let view: NSView = StandIn(frame: NSRect(x: 500, y: 0, width: 500, height: 600))
            var tmuxSessionID: String? { nil }
            var onFocusRequested: (() -> Void)?
            var onDetach: (() -> Void)?
            let cellMetrics: TerminalCellMetrics = .unavailable
            var onCellMetricsChanged: (() -> Void)?
            func start() {}
            func stop() {}
            func focus(in window: NSWindow?) { window?.makeFirstResponder(view) }
            func connect(to config: TerminalLaunchConfig) throws {}
        }
        let stack = InWindowModalStack()
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 600))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let tracker = StandIn(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        let terminal = StandInTerminalHost()
        let host = InWindowModalHost(stack: stack)
        content.addSubview(tracker)
        content.addSubview(terminal.view)
        host.frame = content.bounds
        content.addSubview(host)
        window.contentView = content
        let navigation = NavigationStore()
        let coordinator = ShellFocusCoordinator(
            navigation: navigation,
            window: { window },
            splitView: { nil },
            terminalShell: { nil },
            topDockShell: { nil },
            bottomDockShell: { nil },
            dockColumn: { nil },
            dockPanels: { DockPanels() },
            footerShell: { nil },
            trackerHosting: { tracker },
            dockView: { nil },
            versionControlPane: { nil },
            terminalHost: { terminal },
            modalHost: { host },
            updateDockTabs: {}
        )
        host.onEmpty = { coordinator.focusCurrentRegion() }
        window.show(key: true)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        func presentModal() {
            stack.present(id: "modal", AnyView(Color.clear.frame(width: 120, height: 80)))
            settle()
        }
        coordinator.focus(.tracker)
        settle()
        try expect(window.firstResponder === tracker, "the tracker should start with the keys")

        // New Session's Summon: close(), then onSuccess's switchTerminal focuses the new terminal at once.
        presentModal()
        stack.dismiss(id: "modal")
        coordinator.focusTerminal()
        try expect(window.firstResponder === host, "a focus request during the fade-out should leave the keys on the host")
        settle()
        try expect(window.firstResponder === terminal.view, "after Summon the terminal should have the keys, got \(String(describing: window.firstResponder))")

        coordinator.focus(.tracker)
        presentModal()
        coordinator.focusTerminal()
        try expect(window.firstResponder === host, "focusing the terminal (⌥⌘2, a session switch) under a modal should leave the keys on it, got \(String(describing: window.firstResponder))")
        coordinator.focusRegionLeft()
        try expect(window.firstResponder === host, "a region move (⇧⌘H) under a modal should leave the keys on it, got \(String(describing: window.firstResponder))")
        try expect(navigation.focusedRegion == .tracker, "the region move should still update navigation")
        coordinator.focusTerminal()
        stack.dismiss(id: "modal")
        settle()
        try expect(window.firstResponder === terminal.view, "the last request should take the keys once the modal has faded, got \(String(describing: window.firstResponder))")
    }

    /// The dock's frame lifts while the dock is the focused region and no modal is drawn: a modal opening over the
    /// focused dock drops it, a dock focus request deferred under a modal doesn't light it, and it lights once the
    /// modal has faded.
    private static func testDockFrameFollowsFocusAndModals() throws {
        final class StandIn: NSView { override var acceptsFirstResponder: Bool { true } }
        let stack = InWindowModalStack()
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 600))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let tracker = StandIn(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        let dock = DockShellView(body: NSView())
        dock.frame = NSRect(x: 600, y: 0, width: 400, height: 600)
        let host = InWindowModalHost(stack: stack)
        content.addSubview(tracker)
        content.addSubview(dock)
        host.frame = content.bounds
        content.addSubview(host)
        window.contentView = content
        let navigation = NavigationStore()
        let coordinator = ShellFocusCoordinator(
            navigation: navigation,
            window: { window },
            splitView: { nil },
            terminalShell: { nil },
            topDockShell: { nil },
            bottomDockShell: { dock },
            dockColumn: { nil },
            dockPanels: { DockPanels(bottom: true) },
            footerShell: { nil },
            trackerHosting: { tracker },
            dockView: { nil },
            versionControlPane: { nil },
            terminalHost: { nil },
            modalHost: { host },
            updateDockTabs: {}
        )
        host.onEmpty = { coordinator.focusCurrentRegion() }
        host.onDrawingChange = { coordinator.updateRegionKeys() }
        window.show(key: true)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }

        coordinator.focus(.dock)
        try expect(dock.isFocused, "the dock's frame should lift while the dock has focus")
        coordinator.focus(.tracker)
        try expect(!dock.isFocused, "the frame should drop when focus leaves the dock")

        coordinator.focus(.dock)
        stack.present(id: "modal", AnyView(Color.clear.frame(width: 120, height: 80)))
        settle()
        try expect(!dock.isFocused, "a modal over the focused dock should drop its frame")
        stack.dismiss(id: "modal")
        settle()
        try expect(dock.isFocused, "the frame should lift again once the modal has faded")

        coordinator.focus(.tracker)
        stack.present(id: "modal", AnyView(Color.clear.frame(width: 120, height: 80)))
        settle()
        coordinator.focus(.dock)
        try expect(!dock.isFocused, "a dock focus request deferred under a modal should not light the frame")
        stack.dismiss(id: "modal")
        settle()
        try expect(dock.isFocused, "the deferred dock focus should light the frame once the modal has faded")
    }

    /// A child (⌘T's New Quest over the Quest Log) closing hands the keys back to what had them in the modal it
    /// uncovers: the filter's field editor, caret where it was, so typing goes on into the filter.
    private static func testClosingAChildRefocusesTheModalItUncovers() throws {
        let stack = InWindowModalStack()
        let store = QuestLogStore()
        store.sync(quests: [QuestItem(id: "q", content: "A quest", projectID: "p", projectName: "p")], repos: [])
        let filter = QuestLogFilter()
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 860))
        let host = InWindowModalHost(stack: stack)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 860)
        window.contentView = host
        window.show(key: true)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: filter, pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        settle()
        filter.focus()
        settle()
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
            throw TestFailure("the filter should take focus, got \(String(describing: window.firstResponder))")
        }
        editor.insertText("ab", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        let field = editor.delegate as? NSTextField

        stack.present(id: "new-quest", AnyView(Color.clear.frame(width: 120, height: 80)))
        settle()
        try expect(window.firstResponder === host, "the child should take the keys from the filter")
        stack.dismiss(id: "new-quest")
        settle()
        guard let restored = window.firstResponder as? NSTextView, restored.isFieldEditor, restored.delegate as? NSTextField === field else {
            throw TestFailure("closing the child should refocus the filter, got \(String(describing: window.firstResponder))")
        }
        try expect(restored.string == "ab" && restored.selectedRange() == NSRange(location: 1, length: 0), "the filter should keep its text and caret, got \(restored.string) \(restored.selectedRange())")
    }

    /// A child closing gives the uncovered field back its whole selection, not just a caret at its start.
    private static func testClosingAChildKeepsTheUncoveredFieldsSelection() throws {
        let stack = InWindowModalStack()
        let store = QuestLogStore()
        store.sync(quests: [QuestItem(id: "q", content: "A quest", projectID: "p", projectName: "p")], repos: [])
        let filter = QuestLogFilter()
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 860))
        let host = InWindowModalHost(stack: stack)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 860)
        window.contentView = host
        window.show(key: true)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: filter, pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        settle()
        filter.focus()
        settle()
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
            throw TestFailure("the filter should take focus, got \(String(describing: window.firstResponder))")
        }
        editor.insertText("abcd", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 2))

        stack.present(id: "new-quest", AnyView(Color.clear.frame(width: 120, height: 80)))
        settle()
        stack.dismiss(id: "new-quest")
        settle()
        guard let restored = window.firstResponder as? NSTextView, restored.isFieldEditor else {
            throw TestFailure("closing the child should refocus the filter, got \(String(describing: window.firstResponder))")
        }
        try expect(restored.string == "abcd" && restored.selectedRange() == NSRange(location: 1, length: 2), "the filter should keep its selection, got \(restored.string) \(restored.selectedRange())")
    }

    /// A text field focused before the first modal (the artifact filter with "foo" typed, then ⌘T, then Esc)
    /// gets its caret back once the last modal has faded, not all its text selected.
    private static func testRestoringFocusAfterTheLastModalKeepsAFieldsCaret() throws {
        let stack = InWindowModalStack()
        let size = CGSize(width: 600, height: 400)
        let window = HeadlessWindow(size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        container.addSubview(field)
        let host = InWindowModalHost(stack: stack)
        host.frame = container.bounds
        container.addSubview(host)
        window.contentView = container
        window.show(key: true)
        defer { window.close() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.4)) }
        settle()
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else {
            throw TestFailure("the field should take focus")
        }
        editor.insertText("foo", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 0))

        stack.present(id: "modal", AnyView(Color.clear.frame(width: 120, height: 80)))
        settle()
        try expect(window.firstResponder === host, "the modal should take the keys from the field")
        stack.dismiss(id: "modal")
        settle()
        guard let restored = window.firstResponder as? NSTextView, restored.isFieldEditor, restored.delegate as? NSTextField === field else {
            throw TestFailure("the last modal fading should refocus the field, got \(String(describing: window.firstResponder))")
        }
        try expect(restored.string == "foo" && restored.selectedRange() == NSRange(location: 1, length: 0), "the field should keep its text and caret, got \(restored.string) \(restored.selectedRange())")
    }

    /// The log is rebuilt per opening; it opens scrolled to the selection it kept, not at the top.
    private static func testQuestLogOpensScrolledToTheKeptSelection() throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { ((($0 as? NSScrollView).map { [$0] }) ?? []) + scrollViews(in: $0) }
        }
        let store = QuestLogStore()
        store.sync(quests: (1...40).map { QuestItem(id: "q\($0)", content: "Quest \($0)", projectID: "p", projectName: "p") }, repos: [])
        _ = store.handle(.jumpToLast)
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 860))
        let stack = InWindowModalStack()
        let host = InWindowModalHost(stack: stack)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 860)
        window.contentView = host
        window.show()
        defer { window.close() }
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: QuestLogFilter(), pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let list = scrollViews(in: host).min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        guard let list, let height = list.documentView?.frame.height, height > list.contentView.bounds.height else {
            throw TestFailure("the 40-quest list should overflow its scroll view")
        }
        try expect(list.contentView.bounds.origin.y > 0, "the log should open scrolled to the last quest, offset \(list.contentView.bounds.origin.y)")
    }

    /// The filter's focus (and so its border) follows the window's real first responder: on when the field
    /// takes focus, off when focus leaves (Esc hands it to nil, a click on the list hands it elsewhere).
    private static func testFilterFieldFocusFollowsTheFirstResponder() throws {
        let window = HeadlessWindow(size: CGSize(width: 300, height: 80))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let field = CommandTextField.KeyTextField(frame: NSRect(x: 10, y: 30, width: 200, height: 20))
        let other = NSTextField(frame: NSRect(x: 10, y: 0, width: 200, height: 20))
        content.addSubview(field)
        content.addSubview(other)
        window.contentView = content
        window.show()
        defer { window.close() }
        var reported: [Bool] = []
        field.onFirstResponderChange = { reported.append($0) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
        settle()

        window.makeFirstResponder(field)
        settle()
        try expect(reported.last == true && field.hasFocus, "taking focus should light the field, reported \(reported)")
        window.makeFirstResponder(nil)
        settle()
        try expect(reported.last == false && !field.hasFocus, "Esc (focus to nil) should clear it, reported \(reported)")
        window.makeFirstResponder(field)
        settle()
        window.makeFirstResponder(other)
        settle()
        try expect(reported.last == false && !field.hasFocus, "focus moving elsewhere should clear it, reported \(reported)")
    }

    /// The shell rows as the tracker mock lays them out, measured on the rendered section: 35 tall with no gap, each as
    /// wide as the 260 column, the 25pt disc 10 into the row and the title 10 past it. The viewed shell and the cursor's
    /// shell fill their rows, a resting row between them.
    private static func testShellRowsKeepTheMocksGeometry() throws {
        let sessions = ["a", "b", "c"].map { TrackerSession(id: $0, title: "Shell \($0)", repoName: "", agent: "") }
        let shells = sessions.map { session in
            TrackerRenderedShell(
                rendered: TrackerRenderedSession(session: session, status: TrackerRenderer.status(for: session), groupColor: AppPalette.muted, recolorEditHint: nil),
                repoName: ""
            )
        }
        let size = CGSize(width: TrackerPlateDesign.topLevelSize.width, height: 3 * TrackerShellMetrics.rowHeight)
        func render(selected: String, viewed: String) throws -> PixelProbe {
            let section = TrackerShellRows(
                shells: shells, selectedID: selected, viewedID: viewed, areaFocused: true, shortcutNumbers: [:], commandLongPressIsActive: false,
                onSelect: { _ in }, onActivate: { _ in }, onEditSession: { _ in }
            )
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(AppPalette.window.swiftUI)
            let view = NSHostingView(rootView: section)
            view.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: size, scale: 1)
            window.contentView = view
            window.show()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else {
                throw TestFailure("could not make a bitmap")
            }
            bitmap.size = size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return PixelProbe(bitmap: bitmap, height: Int(size.height))
        }
        let rowHeight = Int(TrackerShellMetrics.rowHeight)
        let middle = rowHeight / 2
        let edgeColumn = 200

        // The viewed shell (a) is filled, the cursor's (b) is outlined with no fill, and c rests.
        let probe = try render(selected: "b", viewed: "a")

        // Down a column past the row's corner and left of the disc: only the viewed row is filled, 35 high from the top.
        let fillColumn = Int(TrackerShellMetrics.cornerRadius) + 1
        let filledRows = (0..<Int(size.height)).filter { probe.isColor(fillColumn, $0, AppPalette.item) }
        try expect(filledRows == Array(0..<rowHeight), "only the viewed row should be filled, 35 high, got rows \(filledRows)")

        // Across the viewed row's middle: the fill runs the column's whole width, flush with the plates.
        let filledColumns = (0..<Int(size.width)).filter { probe.isColor($0, middle, AppPalette.item) }
        try expect(filledColumns.first == 0, "a row should start at the column's edge, got x \(String(describing: filledColumns.first))")
        try expect(filledColumns.last == Int(size.width) - 1, "a row should run to the column's far edge, got x \(String(describing: filledColumns.last))")

        // The cursor's row, with no gap under the filled one, stays apart: its 1pt controlBorder outline is inside its own
        // 35 rows (top row, bottom row and left edge), and its inside is unfilled.
        try expect(probe.isColor(edgeColumn, rowHeight - 1, AppPalette.item), "the viewed row should fill down to its own last row")
        try expect(probe.isColor(edgeColumn, rowHeight, AppPalette.controlBorder), "the cursor's outline should start on its own first row, right under the fill")
        try expect(probe.isColor(edgeColumn, 2 * rowHeight - 1, AppPalette.controlBorder), "the cursor's outline should end on its own last row")
        try expect(probe.isColor(0, rowHeight + middle, AppPalette.controlBorder), "the cursor's outline should run along its left edge")
        try expect(probe.isColor(edgeColumn, rowHeight + middle, AppPalette.window), "the cursor's row should have no fill")

        // The resting row, last: its disc's border starts 10 into the row, and its title 10 past the disc.
        let restMiddle = 2 * rowHeight + middle
        let inkColumns = (0..<Int(size.width)).filter { !probe.isColor($0, restMiddle, AppPalette.window) }
        let discLeft = Int(TrackerShellMetrics.discLead)
        try expect(inkColumns.first == discLeft, "the disc should start 10 into the row, got x \(String(describing: inkColumns.first))")
        let titleLeft = discLeft + Int(TrackerShellMetrics.discDiameter + Space.item)
        let titleInk = inkColumns.first { $0 > discLeft + Int(TrackerShellMetrics.discDiameter) }
        try expect(titleInk.map { $0 >= titleLeft && $0 <= titleLeft + 3 } == true, "the title should start 10 past the disc, got x \(String(describing: titleInk))")

        // The cursor on the viewed shell: filled and outlined, the outline on the fill's own edge rows.
        let both = try render(selected: "a", viewed: "a")
        try expect(both.isColor(edgeColumn, 0, AppPalette.controlBorder) && both.isColor(edgeColumn, rowHeight - 1, AppPalette.controlBorder), "the viewed shell under the cursor should be outlined top and bottom")
        try expect(both.isColor(edgeColumn, middle, AppPalette.item), "and filled inside the outline")
    }

    /// A real tracker in a headless window at 1x, with `masters` plates and `shells` shells (`shell-0` ...), `viewed` the
    /// attached session. The viewed shell's row is filled, which marks where the shell section is.
    private final class TrackerFixture {
        let store: RuntimeStore
        let view: NSView
        let window: HeadlessWindow
        let size: CGSize

        @MainActor
        init(masters: Int, shells: Int, viewed: String, height: Int) {
            func session(_ id: String, role: String) -> TrackerSession {
                TrackerSession(id: id, title: id, repoName: "Repo", agent: role == "shell" ? "shell" : "codex", role: role, state: "idle")
            }
            let plates = (0..<masters).map { session("master-\($0)", role: "master") }
            let shellRows = (0..<shells).map { session("shell-\($0)", role: "shell") }
            store = RuntimeStore(sourceLabel: "test", currentTerminalSessionID: viewed, expandedMasterIDs: [])
            store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [TrackerRepo(id: "repo", name: "Repo", color: "indigo", sessions: plates + shellRows)])))
            size = CGSize(width: 340, height: CGFloat(height))
            let root = TrackerRootView(
                store: store,
                navigation: NavigationStore(state: AppNavigationState(focusedRegion: .terminal)),
                newSessionPresenter: NewSessionSheetPresenter(),
                destructiveConfirmationPresenter: DestructiveConfirmationPresenter()
            )
            .frame(width: size.width, height: size.height)
            .background(AppPalette.window.swiftUI)
            view = NSHostingView(rootView: root)
            view.frame = NSRect(origin: .zero, size: size)
            window = HeadlessWindow(size: size, scale: 1)
            window.contentView = view
            window.show()
            settle()
        }

        func settle(_ seconds: TimeInterval = 0.8) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        func close() {
            window.close()
        }

        /// The tracker's pixels now.
        func probe() throws -> PixelProbe {
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else {
                throw TestFailure("could not make a bitmap")
            }
            bitmap.size = size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return PixelProbe(bitmap: bitmap, height: Int(size.height))
        }

        /// The scroll view that is `height` tall: the shell section's (the plates' list is the one taller).
        func scrollView(height: CGFloat) -> NSScrollView? {
            func find(in view: NSView) -> NSScrollView? {
                if let scrollView = view as? NSScrollView, abs(scrollView.frame.height - height) < 0.5 {
                    return scrollView
                }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(in: view)
        }
    }

    private struct PixelProbe {
        let bitmap: NSBitmapImageRep
        let height: Int

        func isColor(_ x: Int, _ y: Int, _ color: NSColor) -> Bool {
            guard let pixel = bitmap.colorAt(x: x, y: y), let expected = color.usingColorSpace(.deviceRGB) else {
                return false
            }
            return abs(pixel.redComponent - expected.redComponent) < 0.02
                && abs(pixel.greenComponent - expected.greenComponent) < 0.02
                && abs(pixel.blueComponent - expected.blueComponent) < 0.02
        }

        /// The rows of `color` down a column past a shell row's corner and left of its disc: the filled shell rows.
        var filledShellRows: [Int] {
            let column = Int(TrackerListMetrics.sidePadding + TrackerShellMetrics.cornerRadius) + 1
            return (0..<height).filter { isColor(column, $0, AppPalette.item) }
        }

        /// Nothing of a plate in the band above the section, at several columns.
        func clearBand(above sectionTop: Int) -> Bool {
            let clearTop = sectionTop - Int(TrackerListMetrics.shellClearance)
            return [60, 120, 200].allSatisfy { x in (clearTop..<sectionTop).allSatisfy { isColor(x, $0, AppPalette.window) } }
        }
    }

    /// How far a scroll view has scrolled from the top of its content.
    private static func offsetFromTop(_ scrollView: NSScrollView) -> CGFloat {
        guard let document = scrollView.documentView else {
            return 0
        }
        let visible = scrollView.documentVisibleRect
        return document.isFlipped ? visible.minY : document.frame.height - visible.maxY
    }

    /// The shell section sits on the tracker column's bottom edge, at its bottom margin, however many plates there are:
    /// with few plates there is empty space above it, with many the plates are cut `shellClearance` above it, and with
    /// many shells the section stops at its max height. The viewed shell's filled row marks the section's bottom (the
    /// last shell) or its top (the first).
    private static func testTheShellSectionIsPinnedToTheTrackersBottom() throws {
        let height = 700
        let bottom = height - Int(TrackerListMetrics.verticalPadding) - 1
        let rowHeight = Int(TrackerShellMetrics.rowHeight)
        func probe(masters: Int, shells: Int, viewed: String) throws -> PixelProbe {
            let fixture = TrackerFixture(masters: masters, shells: shells, viewed: viewed, height: height)
            defer { fixture.close() }
            return try fixture.probe()
        }
        func sectionTop(shells: Int) -> Int {
            height - Int(TrackerListMetrics.verticalPadding) - min(shells * rowHeight, Int(TrackerShellMetrics.maxHeight))
        }

        let few = try probe(masters: 1, shells: 2, viewed: "shell-1")
        try expect(few.filledShellRows.last == bottom, "with few plates the section should end at the column's bottom margin, got row \(String(describing: few.filledShellRows.last)) for \(bottom)")
        try expect(few.filledShellRows.suffix(rowHeight).first == bottom - rowHeight + 1, "the viewed shell's row should be 35 high")
        try expect(few.clearBand(above: sectionTop(shells: 2)), "there should be empty space above the section")

        let many = try probe(masters: 14, shells: 2, viewed: "shell-1")
        try expect(many.filledShellRows.last == bottom, "with many plates the section should stay at the column's bottom margin, got row \(String(describing: many.filledShellRows.last)) for \(bottom)")
        try expect(many.clearBand(above: sectionTop(shells: 2)), "the plates should be cut a clearance above the section, leaving its band empty")

        // Past five rows the section stops at its max height, five rows, and the plates keep their clearance above it.
        let crowded = try probe(masters: 14, shells: 8, viewed: "shell-0")
        let crowdedTop = sectionTop(shells: 8)
        try expect(crowdedTop == bottom + 1 - Int(TrackerShellMetrics.maxHeight), "eight shells should stand 175 high")
        try expect(crowded.filledShellRows.contains(crowdedTop) && !crowded.filledShellRows.contains(crowdedTop - 1), "the first of eight shells should be the section's top, got rows \(crowded.filledShellRows.suffix(40))")
        try expect(crowded.clearBand(above: crowdedTop), "the capped section keeps its clearance too")
    }

    /// Many shells at the minimum window height: the section is `maxHeight` tall and scrolls inside itself, its last shell
    /// reachable; a viewed last shell is in view on the first render; the cursor following the viewed session scrolls the
    /// section the least it takes, but not when the pointer moved the cursor there.
    private static func testTheShellSectionScrollsInsideItselfPastItsMaxHeight() throws {
        let height = 600
        let rowHeight = Int(TrackerShellMetrics.rowHeight)
        let maxHeight = Int(TrackerShellMetrics.maxHeight)
        let shells = 14
        let bottom = height - Int(TrackerListMetrics.verticalPadding) - 1
        let sectionTop = bottom + 1 - maxHeight
        let contentHeight = CGFloat(shells * rowHeight)

        // First render with the last shell viewed: it is in view, at the section's bottom, and the section is 175 tall (the
        // row above its first visible one starts at its top, and the band above it is clear).
        let last = TrackerFixture(masters: 14, shells: shells, viewed: "shell-13", height: height)
        defer { last.close() }
        let lastProbe = try last.probe()
        try expect(lastProbe.filledShellRows.last == bottom && lastProbe.filledShellRows.suffix(rowHeight).first == bottom - rowHeight + 1,
                   "a viewed last shell should be in view on the first render, got rows \(lastProbe.filledShellRows.suffix(40))")
        let discColumn = Int(TrackerListMetrics.sidePadding + TrackerShellMetrics.discLead + TrackerShellMetrics.discDiameter / 2)
        let discTop = sectionTop + Int((TrackerShellMetrics.rowHeight - TrackerShellMetrics.discDiameter) / 2)
        try expect(lastProbe.isColor(discColumn, discTop, AppPalette.item), "the section should be 175 tall: its first visible row's disc should sit at \(discTop)")
        try expect(lastProbe.clearBand(above: sectionTop), "the plates should stay above the section's clearance")
        guard let lastScroll = last.scrollView(height: TrackerShellMetrics.maxHeight) else {
            throw TestFailure("no 175pt scroll view: the section should scroll inside itself")
        }
        try expect(abs((lastScroll.documentView?.frame.height ?? 0) - contentHeight) < 0.5, "the section's content should be all \(shells) rows, \(contentHeight) tall, got \(String(describing: lastScroll.documentView?.frame.height))")
        try expect(abs(offsetFromTop(lastScroll) - (contentHeight - TrackerShellMetrics.maxHeight)) < 0.5, "the first render should have scrolled to the last row, got \(offsetFromTop(lastScroll))")

        // The last shell is reachable by scrolling: from the top, the section scrolls down to it.
        let first = TrackerFixture(masters: 14, shells: shells, viewed: "shell-0", height: height)
        defer { first.close() }
        guard let firstScroll = first.scrollView(height: TrackerShellMetrics.maxHeight) else {
            throw TestFailure("no 175pt scroll view when the first shell is viewed")
        }
        try expect(offsetFromTop(firstScroll) == 0, "a viewed first shell needs no scroll, got \(offsetFromTop(firstScroll))")
        let firstProbe = try first.probe()
        try expect(firstProbe.filledShellRows.first(where: { $0 > sectionTop - 1 }) == sectionTop, "the viewed first shell should be the section's top row")
        firstScroll.contentView.scroll(to: NSPoint(x: 0, y: (firstScroll.documentView?.isFlipped ?? true) ? contentHeight - TrackerShellMetrics.maxHeight : 0))
        firstScroll.reflectScrolledClipView(firstScroll.contentView)
        try expect(abs(offsetFromTop(firstScroll) - (contentHeight - TrackerShellMetrics.maxHeight)) < 0.5, "the section should scroll down to its last row")

        // The cursor follows the viewed session: onto the last shell, by the keys' way, the section scrolls the least it takes.
        let moved = TrackerFixture(masters: 14, shells: shells, viewed: "shell-0", height: height)
        defer { moved.close() }
        moved.store.setCurrentTerminalSessionID("shell-13")
        moved.settle()
        guard let movedScroll = moved.scrollView(height: TrackerShellMetrics.maxHeight) else {
            throw TestFailure("no 175pt scroll view after the viewed session moved")
        }
        try expect(abs(offsetFromTop(movedScroll) - (contentHeight - TrackerShellMetrics.maxHeight)) < 0.5, "the cursor onto the last shell should scroll it into view, got \(offsetFromTop(movedScroll))")

        // A cursor the pointer moved is already under it: no scroll.
        let hovered = TrackerFixture(masters: 14, shells: shells, viewed: "shell-0", height: height)
        defer { hovered.close() }
        PointerHighlight.cursor.pointerMoved(to: "shell-13")
        hovered.store.setCurrentTerminalSessionID("shell-13")
        hovered.settle()
        guard let hoveredScroll = hovered.scrollView(height: TrackerShellMetrics.maxHeight) else {
            throw TestFailure("no 175pt scroll view after the pointer moved the cursor")
        }
        try expect(offsetFromTop(hoveredScroll) == 0, "a cursor the pointer moved should not scroll the section, got \(offsetFromTop(hoveredScroll))")
    }

    /// The spacing the source scan can't see (AGENTS.md, "Spacing"), measured on 1x renders: stacked paddings and row
    /// internals. The artifact rows' tiles sit on a 45pt pitch (a 40pt row and 5) and are 30 high; a form's first field
    /// starts 10 under the header's band, and the next 20 under it. Each is found as the `line`-coloured border rows
    /// in one pixel column.
    private static func testRenderedSpacingStaysOnTheScale() throws {
        func borderRows(_ view: NSView, size: CGSize, x: Int) throws -> [Int] {
            view.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: size, scale: 1)
            window.contentView = view
            window.show()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ), let line = AppPalette.line.usingColorSpace(.deviceRGB) else {
                throw TestFailure("could not make a bitmap")
            }
            bitmap.size = size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return (0..<Int(size.height)).filter { y in
                guard let pixel = bitmap.colorAt(x: x, y: y) else {
                    return false
                }
                return abs(pixel.redComponent - line.redComponent) < 0.01
                    && abs(pixel.greenComponent - line.greenComponent) < 0.01
                    && abs(pixel.blueComponent - line.blueComponent) < 0.01
            }
        }

        // Inside the tile, past its 5pt corner and clear of its glyph: the gutter, the tile's inset, and 6.
        let tileColumn = Int(Space.section + Space.item) + 6
        let pane = CGSize(width: 480, height: 1015)
        let paneRows = try borderRows(RenderPreview.artifactPaneView(highlight: nil), size: pane, x: tileColumn)
        // The tiles are the last borders down the column: a top and a bottom edge each, the eleven fixture rows.
        let tiles = Array(paneRows.suffix(22))
        try expect(tiles.count == 22, "the artifact tiles' borders should show in the column, got rows \(paneRows)")
        let tops = stride(from: 0, to: tiles.count, by: 2).map { tiles[$0] }
        for (top, bottom) in zip(tops, stride(from: 1, to: tiles.count, by: 2).map { tiles[$0] }) {
            try expect(bottom - top + 1 == 30, "an artifact tile should be 30 high, got rows \(top)-\(bottom)")
        }
        for (above, below) in zip(tops, tops.dropFirst()) {
            try expect(below - above == 45, "artifact rows should sit 45 apart, got tiles at \(above) and \(below)")
        }

        let fieldColumn = Int(ModalFormMetrics.inset + Space.section)
        let formSize = CGSize(width: 460, height: ModalFormMetrics.height(fields: 2))
        let form = NSHostingView(rootView: ModalFormSheet(title: "Spacing", errorMessage: nil, primaryLabel: "Save", canSubmit: true, size: formSize, onCancel: {}, onPrimary: {}) {
            VStack(spacing: ModalFormMetrics.fieldSpacing) {
                FormTextField(text: .constant(""), placeholder: "First", focusNonce: 0, focused: false)
                FormTextField(text: .constant(""), placeholder: "Second", focusNonce: 0, focused: false)
            }
        }.background(AppPalette.panel.swiftUI))
        let fieldEdges = try borderRows(form, size: formSize, x: fieldColumn).filter { CGFloat($0) >= ModalSheetHeader.height }
        try expect(fieldEdges.first == Int(ModalSheetHeader.height + Space.item), "the first field should start 10 under the header's band, got rows \(fieldEdges)")
        let secondTop = Int(ModalFormMetrics.contentTop + FormFieldMetrics.height + ModalFormMetrics.fieldSpacing)
        try expect(fieldEdges.contains(secondTop) && !fieldEdges.contains(secondTop - 1), "the second field should start 20 under the first, got rows \(fieldEdges)")

        // The title row: a 40pt portrait disc, then the 35 high title field 10 right of it and top-aligned with it; the next
        // field starts 20 under the disc.
        let titleSize = CGSize(width: 460, height: ModalFormMetrics.height(fields: 2, portraitRow: true))
        let titleForm = NSHostingView(rootView: ModalFormSheet(title: "Spacing", errorMessage: nil, primaryLabel: "Save", canSubmit: true, size: titleSize, onCancel: {}, onPrimary: {}) {
            VStack(spacing: ModalFormMetrics.fieldSpacing) {
                SessionTitleRow(portrait: .master(.paladin), portraitLabel: "Class Paladin") {
                    FormTextField(text: .constant(""), placeholder: "Title", focusNonce: 0, focused: false)
                }
                FormTextField(text: .constant(""), placeholder: "Second", focusNonce: 0, focused: false)
            }
        }.background(AppPalette.panel.swiftUI))
        let rowTop = Int(ModalFormMetrics.contentTop)
        let discColumn = Int(ModalFormMetrics.inset + SessionPortraitMetrics.sheetDiameter / 2)
        let discRows = try borderRows(titleForm, size: titleSize, x: discColumn).filter { CGFloat($0) >= ModalSheetHeader.height }
        try expect(discRows.first == rowTop && discRows.contains(rowTop + 39), "the portrait disc should be 40 high from the row's top, got rows \(discRows)")
        let titleColumn = Int(ModalFormMetrics.inset + SessionPortraitMetrics.sheetDiameter + Space.item + Space.section)
        let titleRows = try borderRows(titleForm, size: titleSize, x: titleColumn).filter { CGFloat($0) >= ModalSheetHeader.height }
        try expect(titleRows.first == rowTop && titleRows.contains(rowTop + Int(FormFieldMetrics.height) - 1), "the title field should be 35 high from the row's top, got rows \(titleRows)")
        let nextTop = rowTop + Int(SessionPortraitMetrics.sheetDiameter + ModalFormMetrics.fieldSpacing)
        try expect(titleRows.contains(nextTop) && !titleRows.contains(nextTop - 1), "the next field should start 20 under the disc, got rows \(titleRows)")
    }

    /// The elevation shadows (AGENTS.md, "Interaction states") reach past the clip that shapes their panel: a modal's
    /// from `scoopedPanel`, the dock's from `ScoopedLayerChrome`. A pixel 2pt under each panel's bottom edge, on the
    /// window fill, must be darker than the same fill far from it, and only a shadow dropped downward is that dark
    /// there.
    private static func testChromeShadowsReachPastTheirClips() throws {
        func darkness(_ view: NSView, size: CGSize, belowPanelAt probe: CGPoint) throws -> CGFloat {
            view.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: size, scale: 1)
            window.contentView = view
            window.show()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else {
                throw TestFailure("could not make a bitmap")
            }
            bitmap.size = size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let shadowed = bitmap.colorAt(x: Int(probe.x), y: Int(probe.y)), let bare = bitmap.colorAt(x: 2, y: 2), bare.redComponent > 0 else {
                throw TestFailure("could not read the render")
            }
            return shadowed.redComponent / bare.redComponent
        }

        let margin = Space.group + Space.section
        let panel = CGSize(width: 200, height: 120)
        let canvas = CGSize(width: panel.width + 2 * margin, height: panel.height + 2 * margin)
        let probe = CGPoint(x: canvas.width / 2, y: margin + panel.height + 2)
        let modal = NSHostingView(rootView: Color.clear.frame(width: panel.width, height: panel.height).scoopedPanel().padding(margin).background(AppPalette.window.swiftUI))
        let modalDarkness = try darkness(modal, size: canvas, belowPanelAt: probe)
        try expect(modalDarkness < 0.92, "a modal's shadow should show under its panel, got \(modalDarkness) of the window fill")

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = AppPalette.window.cgColor
        let dock = DockShellView(body: NSView())
        dock.frame = NSRect(x: margin, y: margin, width: panel.width, height: panel.height)
        container.addSubview(dock)
        let dockDarkness = try darkness(container, size: canvas, belowPanelAt: probe)
        try expect(dockDarkness < 0.92, "the dock's shadow should show under its panel, got \(dockDarkness) of the window fill")
    }

    /// No single-line text field is shorter than its font's full line (ascent + descent + leading): the live
    /// field editor clips to the field's bounds, so a shorter field cuts ascenders or descenders.
    /// The title row's model for the class-segment test: the segment's text, and the title field's.
    @MainActor
    private final class TitleRowModel: ObservableObject {
        @Published var label = "Random"
        @Published var text: String

        init(text: String) {
            self.text = text
        }
    }

    /// The title row of New Session as it is laid out, in a 460 x 60 canvas.
    private struct TitleRowHarness: View {
        @ObservedObject var model: TitleRowModel
        let placeholder: String

        var body: some View {
            SessionTitleRow(portrait: .master(nil), portraitLabel: "Class") {
                FormTextField(text: Binding(get: { model.text }, set: { model.text = $0 }), placeholder: placeholder, focusNonce: 0, focused: true) {
                    FormFieldSegment(text: model.label, color: AppPalette.textMeta)
                }
            }
            .frame(width: 460, height: 60, alignment: .topLeading)
            .background(AppPalette.panel.swiftUI)
        }
    }

    /// A filter bar (the Quest Log's and the artifact dock's) with one chip, in a 340 x 60 canvas.
    private struct FilterBarHarness: View {
        @State var query: String
        let tokens: [ArtifactFilterToken]

        var body: some View {
            FilterBar(
                tokens: tokens,
                query: $query,
                placeholder: "xHH",
                focusNonce: 0,
                suggestions: [],
                highlightedSuggestionID: nil,
                accessibilityLabel: "Filter",
                onCommand: { _ in false },
                onRemoveToken: { _ in },
                onSelectSuggestion: { _ in }
            )
            .frame(width: 340)
            .frame(width: 340, height: 60, alignment: .topLeading)
            .background(AppPalette.panel.swiftUI)
        }
    }

    // The helpers of the text-position tests: pixels of a view at a backing scale, the ink edges of glyphs in them, and
    // where a field editor's first line sits.

    private static func findKeyField(in view: NSView) -> CommandTextField.KeyTextField? {
        (view as? CommandTextField.KeyTextField) ?? view.subviews.lazy.compactMap(findKeyField).first
    }

    /// The view's pixels now, at `scale`.
    private static func snapshot(_ view: NSView, size: CGSize, scale: CGFloat) throws -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            throw TestFailure("could not make a bitmap")
        }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// The top and bottom ink edges, in points from the view's top and to the backing pixel, of what differs from
    /// `background` in `columns` (points) within `rows` (points).
    private static func inkEdges(_ bitmap: NSBitmapImageRep, scale: CGFloat, columns: Range<Int>, rows: Range<Int> = 3..<32, over background: NSColor = AppPalette.window) -> (top: CGFloat, bottom: CGFloat)? {
        guard let base = background.usingColorSpace(.deviceRGB) else {
            return nil
        }
        let factor = Int(scale)
        let inked = (rows.lowerBound * factor..<rows.upperBound * factor).filter { y in
            (columns.lowerBound * factor..<columns.upperBound * factor).contains { x in
                guard let pixel = bitmap.colorAt(x: x, y: y) else {
                    return false
                }
                return abs(pixel.redComponent - base.redComponent) + abs(pixel.greenComponent - base.greenComponent)
                    + abs(pixel.blueComponent - base.blueComponent) > 0.15
            }
        }
        guard let first = inked.first, let last = inked.last else {
            return nil
        }
        return (CGFloat(first) / scale, CGFloat(last + 1) / scale)
    }

    /// Where the field editor's first line stands on its baseline, in points from `view`'s top: the glyph's location is in
    /// its line fragment, the line fragment in the text container, and the container sits `textContainerOrigin` into the
    /// editor, which then converts into the view.
    private static func firstLineBaseline(of editor: NSTextView, in view: NSView) -> CGFloat? {
        guard let layout = editor.layoutManager, layout.numberOfGlyphs > 0 else {
            return nil
        }
        let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let glyph = layout.location(forGlyphAt: 0)
        let inEditor = NSPoint(
            x: editor.textContainerOrigin.x + line.minX + glyph.x,
            y: editor.textContainerOrigin.y + line.minY + glyph.y
        )
        return view.convert(inEditor, from: editor).y
    }

    /// A baseline in points, snapped to the backing pixel the glyphs are drawn on, so it compares with an ink edge.
    private static func pixelEdge(_ y: CGFloat, scale: CGFloat) -> CGFloat {
        (y * scale).rounded() / scale
    }

    /// Changing the class changes the segment's width, so the title field is laid out again. Its text must not move when
    /// that happens, nor when the field takes focus: the field editor draws where the resting cell does, always, at 1x and
    /// at 2x (a Retina display), with typed text or the placeholder showing, and the segment stays on its baseline.
    ///
    /// The resting baseline is the bottom ink edge of an "H" in an unfocused twin. The placeholder and the segment are
    /// measured the same way, in pixels. Typed text in a focused field is the editor's, whose pixels a snapshot of the view
    /// doesn't follow, so its baseline is read off the editor's own line (`firstLineBaseline`). Two claims, kept apart: the
    /// text doesn't move across the change (the same measure before and after, exactly), and it sits on the resting
    /// baseline (the editor's, snapped to its backing pixel, against the resting ink edge).
    /// Once AppKit re-laid the editor out after a segment change it sat a point above where the editor was first placed
    /// (the focus clip view's frame is recomputed on a resize, the editor in it is not), which a one-time offset of the
    /// editor, made to match the resting cell, then got wrong.
    private static func testTheTitleFieldsTextStaysPutWhenTheClassSegmentChanges() throws {
        let size = CGSize(width: 460, height: 60)
        // The field starts after the 40pt disc and its 10 gap; its text 10 in. The first "x" takes the caret's place at the
        // start of an empty field, so the title's columns are the "H" after it.
        let titleColumns = 68..<73
        let segmentColumns = 430..<449
        var failures: [String] = []
        for scale in [CGFloat(1), CGFloat(2)] {
            /// A title row in a window at `scale`, its field editing (caret at the end) or not.
            func makeRow(text: String, focused: Bool) throws -> (model: TitleRowModel, view: NSView, window: HeadlessWindow) {
                let model = TitleRowModel(text: text)
                let view = NSHostingView(rootView: TitleRowHarness(model: model, placeholder: "xHH"))
                view.frame = NSRect(origin: .zero, size: size)
                let window = HeadlessWindow(size: size, scale: scale)
                window.contentView = view
                window.show(key: true)
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                if focused {
                    guard let field = findKeyField(in: view) else {
                        throw TestFailure("no title text field")
                    }
                    field.focusEditorAtEnd()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                    try expect(field.currentEditor() != nil, "the title field should be editing")
                }
                return (model, view, window)
            }
            func measure(_ view: NSView) throws -> (title: CGFloat?, segment: CGFloat?) {
                let bitmap = try snapshot(view, size: size, scale: scale)
                return (inkEdges(bitmap, scale: scale, columns: titleColumns)?.bottom, inkEdges(bitmap, scale: scale, columns: segmentColumns)?.bottom)
            }
            func editorBaseline(_ view: NSView) -> CGFloat? {
                (findKeyField(in: view)?.currentEditor() as? NSTextView).flatMap { firstLineBaseline(of: $0, in: view) }
            }

            let resting = try makeRow(text: "xHH", focused: false)
            defer { resting.window.close() }
            guard let restingBaseline = try measure(resting.view).title else {
                throw TestFailure("the resting title should show ink at \(scale)x")
            }

            for (name, text, focused) in [("typed, focused", "xHH", true), ("typed, unfocused", "xHH", false), ("placeholder, focused", "", true), ("placeholder, unfocused", "", false)] {
                let row = try makeRow(text: text, focused: focused)
                defer { row.window.close() }
                let before = try measure(row.view)
                let editorBefore = editorBaseline(row.view)
                row.model.label = "Paladin"
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                let after = try measure(row.view)
                let editorAfter = editorBaseline(row.view)
                let label = "\(scale)x \(name)"

                if before.segment == nil || before.segment != after.segment {
                    failures.append("\(label): the segment's baseline should not move, \(String(describing: before.segment)) to \(String(describing: after.segment))")
                }
                if focused && !text.isEmpty {
                    // Typed text under the editor: it doesn't move across the change, and it stands on the resting baseline.
                    guard let editorBefore, let editorAfter else {
                        failures.append("\(label): the editor should have a first line")
                        continue
                    }
                    if editorBefore != editorAfter {
                        failures.append("\(label): the editor's baseline moved when the class changed, \(editorBefore) to \(editorAfter)")
                    }
                    if pixelEdge(editorBefore, scale: scale) != restingBaseline || pixelEdge(editorAfter, scale: scale) != restingBaseline {
                        failures.append("\(label): the editor's baseline \(editorBefore) / \(editorAfter) should stand on the resting \(restingBaseline)")
                    }
                } else {
                    if before.title != after.title {
                        failures.append("\(label): the title's baseline moved when the class changed, \(String(describing: before.title)) to \(String(describing: after.title))")
                    }
                    if before.title != restingBaseline {
                        failures.append("\(label): the title's baseline should be the resting \(restingBaseline), got \(String(describing: before.title))")
                    }
                }
            }
        }
        try expect(failures.isEmpty, failures.joined(separator: "; "))
    }

    /// The real Edit Session sheet: ⌃e in its focused title cycles a classless master from Random to paladin, the segment
    /// widens by a letter, the title field is laid out again, and the editor's text stays where it was.
    private static func testEditSessionKeepsItsTitleTextStillWhenControlECyclesTheClass() throws {
        func editingField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.currentEditor() != nil {
                return field
            }
            return view.subviews.lazy.compactMap(editingField).first
        }
        for scale in [CGFloat(1), CGFloat(2)] {
            let session = TrackerEditSession(sessionID: "qm-1", title: "Small fixes", color: "orange", allowsColor: true, portrait: .choosing(nil))
            let size = CGSize(width: 460, height: 300)
            let sheet = TrackerEditSessionSheet(session: session, dismiss: {}, save: { _, _, _ in true })
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(AppPalette.window.swiftUI)
            let view = NSHostingView(rootView: sheet)
            view.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: size, scale: scale)
            window.contentView = view
            window.show(key: true)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            func baseline() throws -> (y: CGFloat, width: CGFloat) {
                guard let field = editingField(in: view), let editor = field.currentEditor() as? NSTextView,
                      let y = firstLineBaseline(of: editor, in: view) else {
                    throw TestFailure("the Edit Session title should be editing at \(scale)x")
                }
                return (y, field.frame.width)
            }
            let before = try baseline()
            guard let controlE = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{5}", charactersIgnoringModifiers: "\u{5}",
                isARepeat: false, keyCode: 14
            ) else {
                throw TestFailure("could not make a ⌃e key event")
            }
            NSApp.sendEvent(controlE)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let after = try baseline()
            try expect(before.width - after.width > 5, "⌃e should widen the class segment and narrow the title field at \(scale)x, got \(before.width) to \(after.width)")
            try expect(before.y == after.y, "the Edit Session title's text should not move when ⌃e cycles the class at \(scale)x, baseline \(before.y) to \(after.y)")
        }
    }

    /// The filter bar (the Quest Log's and the artifact dock's) places its text field by its first baseline, so the lost
    /// point of field height moved nothing: at 1x and 2x, with one chip and with none (the usual state), its text rests, and
    /// is focused, on one baseline, which is the designs' (21.5 down the bar, on its backing pixel) and, within a backing
    /// pixel, the chip's text's, and the slash stays centred in the bar.
    /// Run under `XDG_CONFIG_HOME=/nonexistent` too, where the font is the system mono and every metric differs: the
    /// claims here are relations, so they hold in either.
    private static func testFilterBarTextSitsOnOneBaselineRestingAndFocused() throws {
        let size = CGSize(width: 340, height: 60)
        let token = ArtifactFilterToken(kind: .project, value: "x", title: "HHH")
        // The bar's "/" is 10 in; the chip's "HHH" follows its "@project " (the chip is 10 past the slash and its text 5 in).
        // The field's text starts after the chip, or after the slash with none; its first "x" takes the caret's place at the
        // start of an empty field, so the columns are the "H" after it.
        let slashColumns = 10..<17
        let chipColumns = 98..<118
        var failures: [String] = []
        for (chips, fieldColumns) in [(1, 142..<146), (0, 38..<42)] {
            for scale in [CGFloat(1), CGFloat(2)] {
                let tolerance = 0.5 + 0.001
                let name = "\(scale)x, \(chips) chip\(chips == 1 ? "" : "s")"
                func makeBar(query: String, focused: Bool) throws -> (view: NSView, window: HeadlessWindow) {
                    let view = NSHostingView(rootView: FilterBarHarness(query: query, tokens: chips == 1 ? [token] : []))
                    view.frame = NSRect(origin: .zero, size: size)
                    let window = HeadlessWindow(size: size, scale: scale)
                    window.contentView = view
                    window.show(key: true)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                    if focused {
                        guard let field = findKeyField(in: view) else {
                            throw TestFailure("no filter text field")
                        }
                        field.focusEditorAtEnd()
                        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                        try expect(field.currentEditor() != nil, "the filter field should be editing")
                    }
                    return (view, window)
                }
                func fieldBaseline(_ bar: (view: NSView, window: HeadlessWindow)) throws -> CGFloat? {
                    inkEdges(try snapshot(bar.view, size: size, scale: scale), scale: scale, columns: fieldColumns)?.bottom
                }

                let resting = try makeBar(query: "xHH", focused: false)
                defer { resting.window.close() }
                let bitmap = try snapshot(resting.view, size: size, scale: scale)
                guard let restingBaseline = inkEdges(bitmap, scale: scale, columns: fieldColumns)?.bottom,
                      let slash = inkEdges(bitmap, scale: scale, columns: slashColumns) else {
                    throw TestFailure("\(name): the filter bar's text and slash should show ink")
                }
                let designBaseline = pixelEdge(FormFieldMetrics.baseline, scale: scale)
                if restingBaseline != designBaseline {
                    failures.append("\(name): the filter text's baseline \(restingBaseline) should be the designs' \(FormFieldMetrics.baseline) down the bar, on the backing pixel \(designBaseline)")
                }
                if chips == 1 {
                    guard let chip = inkEdges(bitmap, scale: scale, columns: chipColumns, rows: 12..<24, over: AppPalette.item) else {
                        throw TestFailure("\(name): the chip's text should show ink")
                    }
                    if abs(restingBaseline - chip.bottom) > tolerance {
                        failures.append("\(name): the filter text's baseline \(restingBaseline) should be the chip text's \(chip.bottom)")
                    }
                }
                if abs((slash.top + slash.bottom) / 2 - FilterBarMetrics.height / 2) > tolerance {
                    failures.append("\(name): the slash (\(slash)) should stay centred in the \(FilterBarMetrics.height) bar")
                }

                let restingPlaceholder = try makeBar(query: "", focused: false)
                defer { restingPlaceholder.window.close() }
                if try fieldBaseline(restingPlaceholder) != restingBaseline {
                    failures.append("\(name): the resting placeholder should sit on the resting text's baseline \(restingBaseline), got \(String(describing: try fieldBaseline(restingPlaceholder)))")
                }
                let focusedPlaceholder = try makeBar(query: "", focused: true)
                defer { focusedPlaceholder.window.close() }
                if try fieldBaseline(focusedPlaceholder) != restingBaseline {
                    failures.append("\(name): the focused placeholder should stay on \(restingBaseline), got \(String(describing: try fieldBaseline(focusedPlaceholder)))")
                }
                let focusedTyped = try makeBar(query: "xHH", focused: true)
                defer { focusedTyped.window.close() }
                if let editor = findKeyField(in: focusedTyped.view)?.currentEditor() as? NSTextView, let baseline = firstLineBaseline(of: editor, in: focusedTyped.view) {
                    if pixelEdge(baseline, scale: scale) != restingBaseline {
                        failures.append("\(name): the focused editor's baseline \(baseline) should stand on the resting \(restingBaseline)")
                    }
                } else {
                    failures.append("\(name): the focused filter field should have a first line")
                }
            }
        }
        try expect(failures.isEmpty, failures.joined(separator: "; "))
    }

    private static func testTextFieldsFitTheirWholeLine() throws {
        func fields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { subview in
                ((subview as? NSTextField).map { [$0] } ?? []) + fields(in: subview)
            }
        }
        func check<V: View>(_ name: String, _ content: V, size: CGSize) throws {
            let hosting = NSHostingView(rootView: content)
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: CGSize(width: size.width, height: size.height))
            window.contentView = hosting
            window.show()
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let found = fields(in: hosting).filter { $0.isEditable }
            try expect(!found.isEmpty, "\(name): no editable text field found")
            for field in found {
                guard let font = field.font else {
                    continue
                }
                let line = font.ascender - font.descender + font.leading
                try expect(field.bounds.height >= line, "\(name): a \(font.pointSize)pt field is \(field.bounds.height) high, under its \(line) line")
            }
        }
        let store = QuestLogStore()
        store.sync(quests: [QuestItem(id: "q", content: "A quest")], repos: [])
        try check("Quest Log filter", QuestLogView(store: store, filter: QuestLogFilter(), onCommand: { _ in }), size: QuestLogView.size)
        let newSession = NewSessionSheetPresenter()
        newSession.present(initialPath: "/tmp/gjpqy", mutationClient: StubMutationClient(result: .failure(TestFailure("unused"))), directoryClient: nil, onSuccess: { _ in })
        if let presentation = newSession.presentation {
            try check("New Session", NewSessionSheetView(presentation: presentation, dismiss: {}), size: NewSessionSheetModel.sheetSize)
        }
        let newQuest = NewQuestSheetPresenter()
        newQuest.present(projects: [], initialProject: nil, sessionID: nil, mutationClient: StubMutationClient(result: .failure(TestFailure("unused"))), directoryClient: nil, onSuccess: {})
        if let presentation = newQuest.presentation {
            try check("New Quest", NewQuestSheetView(presentation: presentation, dismiss: {}), size: NewSessionSheetModel.sheetSize)
        }
        let editSession = TrackerEditSession(sessionID: "qm-1", title: "gjpqy", color: "orange", allowsColor: true)
        try check("Edit Session", TrackerEditSessionSheet(session: editSession, dismiss: {}, save: { _, _, _ in true }), size: CGSize(width: 460, height: ModalFormMetrics.height(fields: 2)))
        let masterSession = TrackerEditSession(sessionID: "qm-1", title: "gjpqy", color: "orange", allowsColor: true, portrait: .choosing(.cleric))
        try check("Edit Session (master)", TrackerEditSessionSheet(session: masterSession, dismiss: {}, save: { _, _, _ in true }), size: CGSize(width: 460, height: ModalFormMetrics.height(fields: 2, portraitRow: true)))
    }

    /// A long quest's ink scrolls under a wheel over the page: the page's point hit-tests into its scroll view,
    /// and the wheel moves it.
    private static func testQuestLogPageScrollsWithTheWheel() throws {
        let body = (1...60).map { "- Step \($0) of a quest long enough to scroll" }.joined(separator: "\n")
        let store = QuestLogStore()
        store.sync(quests: [QuestItem(id: "q", content: "A long quest\n\n\(body)", projectID: "p", projectName: "p")], repos: [])
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 860))
        let stack = InWindowModalStack()
        let host = InWindowModalHost(stack: stack)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 860)
        window.contentView = host
        window.show()
        defer { window.close() }
        let pageScroll = QuestLogPageScroll()
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: QuestLogFilter(), pageScroll: pageScroll, onCommand: { _ in }))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))

        // The page's middle, in the host's coordinates: the 900 x 780 log is centred, its page 473 wide at (397, 40).
        let logOrigin = NSPoint(x: (1000 - 900) / 2, y: (860 - 780) / 2)
        let pageMiddle = NSPoint(x: logOrigin.x + 397 + 236, y: host.bounds.height - (logOrigin.y + 40 + 330))
        guard let hit = host.hitTest(host.superview?.convert(pageMiddle, from: host) ?? pageMiddle) else {
            throw TestFailure("nothing under the page takes the wheel")
        }
        guard let scrollView = hit as? NSScrollView ?? hit.enclosingScrollView else {
            throw TestFailure("the page hit-tests to \(type(of: hit)), not into a scroll view")
        }
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        try expect(documentHeight > scrollView.contentView.bounds.height, "the long quest should overflow the page: \(documentHeight) vs \(scrollView.contentView.bounds.height)")
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -120, wheel2: 0, wheel3: 0),
              let wheel = NSEvent(cgEvent: cgEvent) else {
            throw TestFailure("could not make a wheel event")
        }
        try expect(pageScroll.moreBelow, "an overflowing page should show the cue that more ink lies below")
        let before = scrollView.contentView.bounds.origin.y
        hit.scrollWheel(with: wheel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try expect(scrollView.contentView.bounds.origin.y != before, "the wheel should scroll the page (offset stayed \(before))")

        // The page keys (PageDown and friends) go through the same scroller; past the end, the cue goes away.
        let afterWheel = scrollView.contentView.bounds.origin.y
        pageScroll.scroll(byPages: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try expect(scrollView.contentView.bounds.origin.y > afterWheel, "a half-page key should scroll further down")
        pageScroll.scroll(byPages: 50)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let maxOffset = documentHeight - scrollView.contentView.bounds.height
        try expect(abs(scrollView.contentView.bounds.origin.y - maxOffset) < 1, "scrolling past the end should stop at the bottom")
        try expect(!pageScroll.moreBelow, "at the bottom the overflow cue should go away")
    }

    /// The Quest Log fades in and its parchment unrolls without the parchment Canvas redrawing frame by frame;
    /// closing fades it out and only then hides the host.
    private static func testQuestLogOpensWithoutRedrawingTheParchment() throws {
        let store = QuestLogStore()
        store.sync(quests: [QuestItem(id: "q", content: "A quest\n\nWith a body", projectID: "p", projectName: "p")], repos: [])
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 860))
        let stack = InWindowModalStack()
        let host = InWindowModalHost(stack: stack)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 860)
        window.contentView = host
        window.show()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        QuestLogDebug.parchmentDraws = 0
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: QuestLogFilter(), pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        try expect(!host.isHidden, "opening should show the Quest Log")
        try expect((1...2).contains(QuestLogDebug.parchmentDraws), "the parchment should draw once for the opening, not per unroll frame; drew \(QuestLogDebug.parchmentDraws) times")

        store.close()
        stack.dismiss(id: QuestLogModal.stackID)
        RunLoop.main.run(until: Date().addingTimeInterval(ModalFade.fadeOut / 3))
        try expect(!host.isHidden, "the Quest Log should stay visible while it fades out")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try expect(host.isHidden, "the Quest Log host should hide once the fade-out ends")
    }

    /// The dock's state is app-wide: through the real dock model, a session switch keeps the viewer on its artifact
    /// and keeps the filter, and the Session list lists the new session's artifacts.
    private static func testDockKeepsItsStateAcrossSessionSwitches() throws {
        let a1 = ArtifactReference(kind: "html", path: "/tmp/a1.html", label: "A1", sessionID: "qm-a", addedAt: "")
        let b1 = ArtifactReference(kind: "html", path: "/tmp/b1.html", label: "B1", sessionID: "qm-b", addedAt: "")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(
            repos: [TrackerRepo(id: "repo", name: "Repo", sessions: [
                TrackerSession(id: "qm-a", title: "A", repoName: "Repo", workerCount: 0, artifacts: [a1]),
                TrackerSession(id: "qm-b", title: "B", repoName: "Repo", workerCount: 0, artifacts: [b1]),
            ])]
        )
        let coordinator = DockCoordinator()
        let model = DockPaneModel()
        model.onSelectedArtifactChange = { coordinator.state.selectedArtifactID = $0 }
        model.onArtifactFilterChange = { query, tokens in
            coordinator.state.artifactFilterQuery = query
            coordinator.state.artifactFilterTokens = tokens
        }

        coordinator.state.showArtifact(a1.id)
        _ = model.apply(coordinator.state, snapshot: snapshot, preferredArtifactSessionID: "qm-a")
        let before = coordinator.state
        _ = model.apply(coordinator.state, snapshot: snapshot, preferredArtifactSessionID: "qm-b")
        try expect(coordinator.state == before, "a session switch should leave the dock state as it was, got \(coordinator.state)")
        try expect(model.artifactModel.displayState == .viewing(a1), "the viewer should stay on A's artifact in B, got \(model.artifactModel.displayState)")

        coordinator.state.setArtifactScope(.all)
        _ = model.apply(coordinator.state, snapshot: snapshot, preferredArtifactSessionID: "qm-b")
        model.setArtifactFilterQuery("a1")
        try expect(coordinator.state.artifactFilterQuery == "a1", "the filter should reach the dock state")
        _ = model.apply(coordinator.state, snapshot: snapshot, preferredArtifactSessionID: "qm-a")
        try expect(model.artifactModel.artifactFilterQuery == "a1", "a session switch should keep the filter")

        coordinator.state.setArtifactScope(.session)
        _ = model.apply(coordinator.state, snapshot: snapshot, preferredArtifactSessionID: "qm-a")
        try expect(model.artifactModel.artifacts == [a1], "the Session list should list A's artifacts")
        _ = model.apply(coordinator.state, snapshot: snapshot, preferredArtifactSessionID: "qm-b")
        try expect(model.artifactModel.artifacts == [b1], "the Session list should follow the switch to B")
    }

    /// Through the real DockPaneModel: with the worker chat as the dock's content, a new artifact still reports its open
    /// intent, so it opens a hidden dock; while the worker chat shows it doesn't open, and the list opened later
    /// doesn't jump to it.
    private static func testNewArtifactsOpenFromBehindTheWorkerChat() throws {
        let a1 = ArtifactReference(kind: "html", path: "/tmp/a1.html", label: "A1", sessionID: "qm-a", addedAt: "")
        let a2 = ArtifactReference(kind: "html", path: "/tmp/a2.html", label: "A2", sessionID: "qm-a", addedAt: "")
        let a3 = ArtifactReference(kind: "html", path: "/tmp/a3.html", label: "A3", sessionID: "qm-a", addedAt: "")
        func snapshot(_ artifacts: [ArtifactReference]) -> RuntimeSnapshot {
            var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
            snapshot.tracker = TrackerSnapshot(repos: [TrackerRepo(id: "repo", name: "Repo", sessions: [
                TrackerSession(id: "qm-a", title: "A", repoName: "Repo", workerCount: 0, artifacts: artifacts),
            ])])
            return snapshot
        }
        let model = DockPaneModel()

        var state = DockState(bottomVisible: false, dockContent: .workerChat)
        _ = model.apply(state, snapshot: snapshot([a1]), preferredArtifactSessionID: "qm-a")
        let hidden = model.apply(state, snapshot: snapshot([a2, a1]), preferredArtifactSessionID: "qm-a")
        try expect(hidden.intent == .open(a2), "a new artifact behind a hidden worker chat should report its open, got \(hidden.intent)")
        try expect(state.openNewArtifact(a2.id) && state.dockContent == .artifactViewer, "it should open the dock on the viewer")

        state = DockState(bottomVisible: true, dockContent: .workerChat)
        let shown = model.apply(state, snapshot: snapshot([a3, a2, a1]), preferredArtifactSessionID: "qm-a")
        if case .open(let artifact) = shown.intent {
            try expect(!state.openNewArtifact(artifact.id), "a new artifact should not open over the worker chat")
        }
        try expect(state.dockContent == .workerChat, "the worker chat should stay")

        state.show(.artifactList)
        let list = model.apply(state, snapshot: snapshot([a3, a2, a1]), preferredArtifactSessionID: "qm-a")
        try expect(list.intent == .none, "opening the list later should not open the artifact that arrived under the worker chat")
        try expect(model.artifactModel.artifacts == [a3, a2, a1], "the list should list the session's artifacts")
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
                            workerCount: 0
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
                            workerCount: 0
                        ),
                    ]
                ),
            ],
            artifacts: [plan, report, screenshot, misc, weekly]
        )

        let model = DockPaneModel()
        _ = model.apply(
            DockState(dockContent: .artifactList, artifactScope: .all),
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
            DockState(dockContent: .artifactList, selectedArtifactID: screenshot.id, artifactScope: .all),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        _ = model.apply(
            DockState(dockContent: .artifactList, artifactScope: .all),
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.artifactModel.selectedArtifactID == screenshot.id, "render refresh should preserve current artifact selection")

        let commandModel = DockPaneModel()
        _ = commandModel.apply(
            DockState(dockContent: .artifactList, artifactScope: .all),
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

        // From here the model renders the app-wide dock state, as the shell does: its filter edits report back to it.
        let coordinator = DockCoordinator()
        coordinator.state = DockState(
            dockContent: .artifactList,
            artifactScope: .all,
            artifactFilterQuery: model.artifactModel.artifactFilterQuery,
            artifactFilterTokens: model.artifactModel.artifactFilterTokens
        )
        model.onArtifactFilterChange = { query, tokens in
            coordinator.state.artifactFilterQuery = query
            coordinator.state.artifactFilterTokens = tokens
        }
        func render(scope: ArtifactScope, session: String) {
            coordinator.state.artifactScope = scope
            _ = model.apply(coordinator.state, snapshot: snapshot, preferredArtifactSessionID: session)
        }

        render(scope: .session, session: "qm-a")
        try expect(model.artifactModel.artifactFilterQuery == "plan", "leaving All should preserve query filter")
        try expect(model.artifactModel.artifactProjectFilterIDs == Set(["repo-b", "_misc"]), "leaving All should preserve project filters")
        try expect(model.artifactModel.artifactTypeFilterIDs.isEmpty, "leaving All should preserve cleared type filters")
        try expect(model.artifactModel.artifacts == [plan], "session scope should ignore persisted All filters")

        render(scope: .all, session: "qm-a")
        try expect(model.artifactModel.artifacts.isEmpty, "returning to All should reapply persisted filters")

        render(scope: .all, session: "qm-b")
        try expect(model.artifactModel.artifactFilterQuery == "plan", "the filter is app-wide: switching sessions should keep its query")
        try expect(
            model.artifactModel.artifactProjectFilterIDs == Set(["repo-b", "_misc"]),
            "the filter is app-wide: switching sessions should keep its tokens"
        )
        try expect(model.artifactModel.artifacts.isEmpty, "the kept filter should still apply in the other session")
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
    }

    private struct DevBackendFixture {
        let root: URL
        let workingDirectory: URL
        let stateRoot: URL
        let go: URL
        let internalGo: URL
        let bundle: AppBackendResolver.BundleInfo
        let environment: [String: String]
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
        for directory in [workingDirectory, stateRoot, resources, macos, root.appendingPathComponent("user-home")] {
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
        try waitForMainQueue("mutation success callback", until: { successes == 1 })
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
        try waitForMainQueue("mutation failure callback", until: { failures.value == 1 })
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
        try waitForMainQueue("switch-before mutation success callback", until: { successes == 1 })
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
        model.state.paths.show(["/a", "/b", "/c"])

        try expect(model.handle(try keyEvent("", keyCode: 125)), "down arrow should be handled")
        try expect(model.state.paths.highlightedIndex == 1, "down arrow should move to the next suggestion")

        try expect(model.handle(try keyEvent("", keyCode: 126)), "up arrow should be handled")
        try expect(model.state.paths.highlightedIndex == 0, "up arrow should move to the previous suggestion")

        try expect(model.handle(try keyEvent("", keyCode: 126)), "up arrow should be handled at the top")
        try expect(model.state.paths.highlightedIndex == 2, "up arrow should wrap to the last suggestion")

        try expect(model.handle(try keyEvent("", keyCode: 125)), "down arrow should be handled at the bottom")
        try expect(model.state.paths.highlightedIndex == 0, "down arrow should wrap to the first suggestion")

        model.state.paths.clear()
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
        try waitForMainQueue("initial model suggestions", until: {
            model.state.model.modelOptions.contains(where: { $0.id == "opus" })
        })
        try expect(client.requests.first?.agent == "claude", "the sheet should resolve models for the initial agent")
        try expect(client.requests.first?.role == "master", "a new agent session should ask for master defaults")
        try expect(client.requests.first?.refresh == false, "the sheet's own resolve on open must not force a refetch")
        try expect(
            model.state.model.modelOptions.contains(where: { $0.id == "opus" }),
            "resolved models should reach the picker"
        )
        try expect(model.state.model.selectedModel == "sonnet", "the field should start on Settings' default, listed or not")

        // Type a model, then change the agent.
        model.state.model.typeModel("opus")
        try expect(model.state.model.selectedModel == "opus", "typed text is the model")

        model.state.model.focusedField = .agent
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the agent select")
        try expect(
            model.state.model.selectedModel != "opus",
            "another harness's model must not carry over"
        )
        try waitForMainQueue("model suggestions for the selected agent", until: {
            model.state.model.modelOptions.contains(where: { $0.id == "gpt-5.6-sol" })
        })
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
        try waitForMainQueueTurn()
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
        try waitForMainQueueTurn()

        // A failed resolve is not the user's problem: no options at all
        // still starts a session with no model override.
        try expect(model.state.model.modelOptions.isEmpty, "a failed resolve should leave no options")
        try expect(model.state.model.selectedModel.isEmpty, "a failed resolve should send no model override")
        try expect(model.state.model.errorMessage == nil, "a failed resolve should not raise a form error")
    }

    private static func testNewSessionDiscardsStaleModelResponseArrivingAfterANewerOne() throws {
        let staleModel = SessionModelOption(id: "opus-initial", label: "opus-initial")
        let freshModel = SessionModelOption(id: "opus-refreshed", label: "opus-refreshed")
        let client = StubModelClient(deferCompletions: true, sequencedModels: [[staleModel], [freshModel]])
        let model = newSessionSheetModel(modelClient: client, initialFocus: .agent)

        model.present()
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the agent")
        try expect(client.requests.count == 2, "opening and the agent change should each fire one request")

        // Fire the newer (agent change) request first, then the stale initial
        // one — the opposite of call order.
        client.fireCompletion(forRequestAt: 1)
        try waitForMainQueue("newer model response", until: {
            model.state.model.modelOptions.contains(where: { $0.id == "opus-refreshed" })
        })
        try expect(
            model.state.model.modelOptions.contains(where: { $0.id == "opus-refreshed" }),
            "the newer response should apply"
        )

        client.fireCompletion(forRequestAt: 0)
        try waitForMainQueueTurn()
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
            efforts: ["claude": ["low", "medium", "high", "xhigh", "max"], "gpt-6-luna": ["low", "medium", "high", "xhigh", "max"], "gpt-6-sol": ["medium", "high"]],
            defaults: ["claude": "xhigh", "gpt-6-luna": "xhigh"]
        )
        let modelClient = StubModelClient(
            models: ["codex": [
                SessionModelOption(id: "gpt-6-luna", label: "gpt-6-luna"),
                SessionModelOption(id: "gpt-6-sol", label: "gpt-6-sol"),
            ]],
            defaults: ["claude": "sonnet", "codex": "gpt-6-luna"]
        )
        let model = newSessionSheetModel(modelClient: modelClient, effortClient: effortClient, initialFocus: .agent)

        model.present()
        try waitForMainQueue("initial reasoning-effort suggestions", until: {
            model.state.model.effortOptions.contains(where: { $0.id == "low" })
        })
        try expect(effortClient.requests.first?.agent == "claude", "the sheet should resolve efforts for the initial agent")
        try expect(effortClient.requests.first?.model.isEmpty == true, "with no default model yet, efforts resolve for no override")
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
        try waitForMainQueue("model suggestions for the selected agent", until: {
            model.state.model.modelOptions.contains(where: { $0.id == "gpt-6-sol" })
        })
        model.state.model.typeModel("gpt-6-sol")
        model.modelChanged()
        try waitForMainQueue("model-specific reasoning-effort suggestions", until: {
            model.state.model.effortOptions.map(\.id) == ["medium", "high"]
        })
        try expect(model.state.model.selectedModel == "gpt-6-sol", "precondition: a real model is selected")
        try expect(effortClient.requests.last?.model == "gpt-6-sol", "selecting a model should re-resolve efforts against it")
        try expect(
            model.state.model.effortOptions.map(\.id) == ["medium", "high"],
            "the model-specific effort levels should reach the picker"
        )
    }

    private static func testNewSessionKeepsDefaultReasoningEffortWhenResolveFails() throws {
        let model = newSessionSheetModel(modelClient: nil, effortClient: nil, initialFocus: .path)

        model.present()

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

    private static func testOneShotServeClientsRejectIncompatibleEnvelopes() throws {
        // Mutations, directory suggestions, models, efforts and worker feed all use sendObject/decodeAck.
        for ok in [true, false] {
            for version in [NSNull() as Any, 1, true] {
                let envelope: [String: Any] = [
                    "protocol_version": version,
                    "type": "response",
                    "ok": ok,
                    "error": "ordinary backend error",
                    "data": ["suggestions": []],
                ]
                let line = try JSONSerialization.data(withJSONObject: envelope)
                do {
                    _ = try UnixSocketMutationClient.decodeAck(line)
                    try expect(false, "incompatible \(ok ? "success" : "error") envelope was accepted")
                } catch let error as ServeClientError {
                    try expect(error.isProtocolVersionMismatch, "version mismatch should win over the response payload")
                }
            }
        }
        _ = try UnixSocketMutationClient.decodeAck(Data("{\"protocol_version\":2,\"type\":\"response\",\"ok\":true,\"data\":{}}".utf8))
    }

    private static func testServeStreamReconnectsAfterProtocolMismatch() throws {
        let fixture = try appBackendFixture()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("qm-protocol-\(UUID().uuidString.prefix(8)).sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try expect(listener >= 0, "could not create test socket")
        defer {
            close(listener)
            unlink(path)
        }
        let bound = try UnixSocketIO.withAddress(path) { address, length in
            Darwin.bind(listener, address, length)
        }
        try expect(bound == 0 && listen(listener, 2) == 0, "could not listen on test socket")

        let lines = [
            "{\"protocol_version\":1,\"type\":\"event\",\"topic\":\"tracker\",\"data\":{\"observed_at\":\"wrong\",\"sessions\":[]}}\n",
            "{\"protocol_version\":2,\"type\":\"event\",\"topic\":\"tracker\",\"data\":{\"observed_at\":\"recovered\",\"sessions\":[]}}\n",
        ]
        DispatchQueue.global().async {
            for line in lines {
                var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 5_000) == 1 else { return }
                let peer = Darwin.accept(listener, nil, nil)
                guard peer >= 0 else { return }
                try? UnixSocketIO.setReadTimeout(on: peer, seconds: 5)
                let hello = "{\"root\":\"\(fixture.stateRoot.path)\",\"identity\":\"canonical\",\"protocol_version\":2,\"accepting\":true}\n"
                try? UnixSocketIO.write(Data(hello.utf8), to: peer)
                var requestBytes = [UInt8](repeating: 0, count: 4096)
                var requestLines = 0
                while requestLines < 2 {
                    let count = Darwin.read(peer, &requestBytes, requestBytes.count)
                    guard count > 0 else { close(peer); return }
                    requestLines += requestBytes[..<count].filter { $0 == 0x0a }.count
                }
                try? UnixSocketIO.write(Data(line.utf8), to: peer)
                close(peer)
            }
        }

        var labels: [String] = []
        let recordJSON: [String: Any] = [
            "running": true, "root": fixture.stateRoot.path, "identity": "canonical", "socket": path,
            "executable": fixture.qm.path, "shim_directory": fixture.root.appendingPathComponent("shim").path,
            "build": "test", "generation": 1, "accepting": true,
        ]
        let record = try JSONDecoder().decode(DaemonRecord.self, from: JSONSerialization.data(withJSONObject: recordJSON))
        let config = LaunchConfiguration.load(arguments: ["--no-daemon-start"], environment: fixture.environment,
                                              workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        let client = UnixSocketServeClient(connection: DaemonConnection(config: config, record: record))
        client.start(onUpdate: { update in
            DispatchQueue.main.async { labels.append(update.observedLabel ?? "") }
        }, onStatus: { _ in })
        try waitForMainQueue("protocol mismatch and recovered tracker stream", until: {
            labels.contains(where: { $0.contains("protocol_version") }) && labels.contains("recovered")
        })
        try expect(!labels.contains("wrong"), "incompatible tracker data should not reach the store")
    }

    // The effort keys are the model field's own: e in its SELECT state, ⌃e in
    // both, and nothing effort-related with focus anywhere else.
    private static func testNewSessionEffortKeysCycleWhereAnECannotBeTyped() throws {
        let effortClient = StubReasoningEffortClient(
            efforts: ["claude": ["low", "high"]],
            defaults: ["claude": "xhigh"]
        )
        let model = newSessionSheetModel(modelClient: nil, effortClient: effortClient, initialFocus: .model)

        model.present()
        try waitForMainQueue("initial reasoning-effort suggestions", until: {
            model.state.model.effortOptions.contains(where: { $0.id == "low" })
        })
        try expect(model.state.model.selectedEffortOption == nil, "precondition: nothing selected, since xhigh isn't in this resolved list")

        try expect(model.handle(try keyEvent("e", keyCode: 14)), "e should be consumed in SELECT")
        try expect(model.state.model.selectedReasoningEffort == "low", "e in SELECT should cycle to the first level")
        try expect(model.state.model.modelMode == .select, "e should not start a search")

        try expect(model.handle(try keyEvent("o", keyCode: 31)), "a letter should be consumed in SELECT")
        try expect(model.state.model.modelMode == .search && model.state.model.modelText == "o", "a letter should start a search on itself")
        try expect(!model.handle(try keyEvent("e", keyCode: 14)), "e should type while searching")
        try expect(model.handle(try keyEvent("\u{5}", keyCode: 14, modifierFlags: .control)), "⌃e should be consumed while searching")
        try expect(model.state.model.selectedReasoningEffort == "high", "⌃e should cycle to the next level")
        try expect(model.handle(try keyEvent("\u{1b}", keyCode: 53)), "Esc should end the search")
        try expect(model.state.model.modelMode == .select && model.state.model.modelText.isEmpty, "Esc should restore the text")

        model.state.model.focusedField = .agent
        try expect(!model.handle(try keyEvent("e", keyCode: 14)), "e on the agent tabs is not an effort key")
        try expect(!model.handle(try keyEvent("\u{5}", keyCode: 14, modifierFlags: .control)), "⌃e on the agent tabs is not an effort key")
        try expect(model.state.model.selectedReasoningEffort == "high", "nothing outside the model field cycles the effort")
    }

    /// ⌃e in the title field cycles the class, Random first; a click on the portrait does the same from any focus. Summon
    /// sends `class` only once one is chosen, so Random leaves the pick to the backend.
    private static func testNewSessionClassCyclesInTheTitleAndSummonSendsAChosenOne() throws {
        let client = StubMutationClient(result: .failure(StubMutationError()))
        let model = NewSessionSheetModel(
            presentation: NewSessionSheetPresentation(
                initialPath: "/tmp/project",
                initialTitle: "",
                initialPrompt: "",
                initialFocus: .title,
                mutationClient: client,
                directoryClient: nil,
                modelClient: nil,
                effortClient: nil,
                onSuccess: { _ in }
            ),
            dismiss: {}
        )
        let controlE = try keyEvent("\u{5}", keyCode: 14, modifierFlags: .control)
        try expect(model.state.model.sessionClass == nil && model.state.model.classLabel == "Random", "the sheet opens on Random")

        model.submit()
        try waitForMainQueue("the first Summon to fail", until: { !model.state.model.submitting })
        try expect(client.sentRequests.count == 1 && client.sentRequests[0].data["class"] == nil, "Random sends no class")

        try expect(model.handle(controlE), "⌃e should be consumed in the title field")
        try expect(model.state.model.sessionClass == .paladin, "the first ⌃e from Random chooses paladin")
        model.cycleClass()
        try expect(model.state.model.sessionClass == .wizard, "a click on the portrait cycles forward too")

        model.state.model.focusedField = .agent
        try expect(!model.handle(controlE), "⌃e on the agent tabs is not a class key")
        try expect(model.state.model.sessionClass == .wizard, "nothing outside the title field cycles the class by key")

        model.submit()
        try waitForMainQueue("the second Summon to fail", until: { !model.state.model.submitting })
        try expect(client.sentRequests.count == 2 && client.sentRequests[1].data["class"] == "wizard", "a chosen class is sent by its id")
    }

    /// The portraits' bundle names are flattened (`class-<id>`, `familiar-<id>`, `random`): each resolves to its own raster,
    /// the class portraits and Random at 150px and the familiars at 120px (3x their 50 and 40pt discs), so a misnamed or
    /// missing file shows here instead of as an empty disc.
    private static func testEveryPortraitIsBundledUnderItsOwnName() throws {
        func pixelWidth(_ portrait: SessionPortrait) throws -> Int {
            guard let image = SessionPortraitImages.image(for: portrait),
                  let representation = image.representations.first else {
                throw TestFailure("no image bundled as \(portrait.resourceName)")
            }
            return representation.pixelsWide
        }
        for sessionClass in SessionClass.allCases {
            try expect(try pixelWidth(.master(sessionClass)) == 150, "\(sessionClass.rawValue)'s class portrait should be 150px")
            try expect(try pixelWidth(.familiar(sessionClass)) == 120, "\(sessionClass.rawValue)'s familiar should be 120px")
        }
        try expect(try pixelWidth(.master(nil)) == 150, "the Random silhouette should be 150px")
    }

    private static func testNewSessionTabTakesTheHighlightedModelThenMovesOn() throws {
        let client = StubModelClient(
            models: ["claude": [SessionModelOption(id: "claude-opus-5-5", label: "claude-opus-5-5")]],
            defaults: ["claude": ""]
        )
        let effortClient = StubReasoningEffortClient(efforts: ["claude": ["low", "high"]], defaults: [:])
        let model = newSessionSheetModel(modelClient: client, effortClient: effortClient, initialFocus: .model)
        model.present()
        try waitForMainQueue("model and effort suggestions", until: {
            !model.state.model.modelOptions.isEmpty && model.state.model.hasEffortLevels
        })
        try expect(model.handle(try keyEvent("o", keyCode: 31)), "a letter should start the search")
        model.state.model.typeModel("opus")
        try expect(model.state.model.showsModelSuggestions, "typing should show the matching model")

        try expect(model.handle(try keyEvent("\t", keyCode: 48)), "Tab should be consumed")
        try expect(model.state.model.selectedModel == "claude-opus-5-5", "Tab should take the highlighted model")
        try expect(model.state.model.modelMode == .select && !model.state.model.showsModelSuggestions, "taking a model should return to SELECT")

        try expect(model.handle(try keyEvent("\t", keyCode: 48)), "Tab should be consumed again")
        try expect(model.state.model.focusedField == .prompt, "the next Tab should move to the prompt: the effort segment is no stop")
    }

    private static func testNewSessionEscapePutsADropdownAwayBeforeClosing() throws {
        var closed = false
        let model = NewSessionSheetModel(
            presentation: NewSessionSheetPresentation(
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
            dismiss: { closed = true }
        )
        model.state.paths.show(["/a"])
        try expect(model.handle(try keyEvent("\u{1b}", keyCode: 53)), "Esc should be consumed")
        try expect(!model.state.showsPathSuggestions && !closed, "the first Esc should only put the dropdown away")
        try expect(model.handle(try keyEvent("\u{1b}", keyCode: 53)), "Esc should be consumed again")
        try expect(closed, "the second Esc should close the sheet")
    }

    /// A typed path goes to serve alone, so it gives the quest the project `quest add --project` would.
    private static func testNewQuestTypedPathSubmitsAPathOnlyProject() throws {
        let client = StubMutationClient(result: .success(ServeMutationAck(data: nil)))
        let sheet = NewQuestSheetModel(
            presentation: NewQuestSheetPresentation(
                projects: [NewQuestProjectOption(projectID: "/tmp/a/.git", projectPath: "/tmp/a", projectName: "a")],
                initialProject: NewQuestProjectOption(projectID: "/tmp/a/.git", projectPath: "/tmp/a", projectName: "a"),
                initialContent: "",
                questID: "",
                sessionID: "",
                mutationClient: client,
                directoryClient: nil,
                onSuccess: {}
            ),
            dismiss: {}
        )
        try expect(sheet.form.projectText == "a", "the session's repo should prefill the project's name")
        try expect(!sheet.form.canSubmit, "Inscribe should wait for content")
        sheet.form.content = "Ship it"
        sheet.form.focusedField = .project
        try expect(sheet.handle(try keyEvent("/", keyCode: 44)), "a / should start a path search")
        sheet.projectTyped("/tmp/b")
        try expect(sheet.form.isPathText && sheet.form.canSubmit, "a path and content are enough")
        sheet.submit()
        let data = client.sentRequests.first?.data
        try expect(data?["project_path"] == "/tmp/b", "the typed path should be sent")
        try expect(data?["project_id"] == nil && data?["project_name"] == nil, "serve derives the id and name")
    }

    private static func newQuestSheet(client: StubMutationClient = StubMutationClient(result: .failure(StubMutationError())), dismiss: @escaping () -> Void = {}) -> NewQuestSheetModel {
        NewQuestSheetModel(
            presentation: NewQuestSheetPresentation(
                projects: [NewQuestProjectOption(projectID: "/tmp/a/.git", projectPath: "/tmp/a", projectName: "a")],
                initialProject: nil,
                initialContent: "Quest",
                questID: "",
                sessionID: "",
                mutationClient: client,
                directoryClient: nil,
                onSuccess: {}
            ),
            dismiss: dismiss
        )
    }

    /// Return on a typed path keeps it, even with a directory row showing; it takes a row only once ↑/↓
    /// chose one. Tab takes the highlighted row.
    private static func testNewQuestReturnKeepsATypedPathUnlessARowWasChosen() throws {
        let sheet = newQuestSheet()
        try expect(sheet.handle(try keyEvent("/", keyCode: 44)), "a / should start a path search")
        sheet.projectTyped("/tmp/typed")
        sheet.paths.show(["/Users/me/recent", "/Users/me/other"])
        try expect(sheet.handle(try keyEvent("\r", keyCode: 36)), "Return should be consumed")
        try expect(sheet.form.projectText == "/tmp/typed" && sheet.form.projectMode == .select, "Return should keep the typed path")

        try expect(sheet.handle(try keyEvent("\u{7f}", keyCode: 51)), "Backspace should edit the path")
        sheet.paths.show(["/Users/me/recent", "/Users/me/other"])
        try expect(sheet.handle(try keyEvent("", keyCode: 125)), "↓ should move in the directories")
        try expect(sheet.handle(try keyEvent("\r", keyCode: 36)), "Return should be consumed")
        try expect(sheet.form.projectText == "/Users/me/other", "Return should take the row ↓ chose")
    }

    private static func testNewQuestLeavingAndReturningToTheProjectFieldEndsItsSearch() throws {
        let sheet = newQuestSheet()
        try expect(sheet.handle(try keyEvent("s", keyCode: 1)), "a letter should start a project search")
        try expect(sheet.form.projectMode == .search, "precondition: searching")
        let sinkBefore = sheet.sinkNonce
        try expect(sheet.handle(try keyEvent("j", keyCode: 38, modifierFlags: .control)), "⌃j should move on")
        try expect(sheet.form.focusedField == .content && sheet.form.projectMode == .select, "leaving should end the search")
        try expect(sheet.sinkNonce == sinkBefore, "leaving should leave the caret to the content, not the sink")
        try expect(sheet.handle(try keyEvent("k", keyCode: 40, modifierFlags: .control)), "⌃k should come back")
        try expect(sheet.form.focusedField == .project && sheet.form.projectMode == .select && sheet.form.projectText == "s", "back in SELECT with the text kept")
        try expect(sheet.sinkNonce == sinkBefore + 1, "SELECT should take the caret out of the text")
    }

    private static func testNewQuestEscapeClosesWhileSubmitting() throws {
        var closed = false
        let client = StubMutationClient(result: .success(ServeMutationAck(data: nil)), deferCompletions: true)
        let sheet = newQuestSheet(client: client, dismiss: { closed = true })
        sheet.form.focusedField = .project
        sheet.projectTyped("/tmp/a")
        sheet.submit()
        try expect(sheet.form.submitting, "precondition: the submit is in flight")
        try expect(sheet.handle(try keyEvent("\u{1b}", keyCode: 53)), "Esc should be consumed")
        try expect(closed, "Esc should close while a submit is in flight")
    }

    private static func testNewSessionControlRRefreshesModelsFromTheModelField() throws {
        let client = StubModelClient(models: ["claude": [SessionModelOption(id: "opus", label: "opus")]], defaults: ["claude": "sonnet"])
        let model = newSessionSheetModel(modelClient: client, initialFocus: .model)
        model.present()
        try waitForMainQueue("initial model suggestions", until: { !model.state.model.modelOptions.isEmpty })
        try expect(client.requests.last?.refresh == false, "the sheet's own resolve should not force a refetch")
        try expect(model.handle(try keyEvent("\u{12}", keyCode: 15, modifierFlags: .control)), "⌃r should be consumed in the model field")
        try waitForMainQueueTurn()
        try expect(client.requests.last?.refresh == true, "⌃r should force a refetch past the catalog cache")
        let count = client.requests.count
        model.state.model.focusedField = .title
        try expect(!model.handle(try keyEvent("\u{12}", keyCode: 15, modifierFlags: .control)), "⌃r elsewhere is not a refresh")
        try expect(client.requests.count == count, "⌃r elsewhere should not refetch")
    }

    private static func newSessionSheetModel(
        modelClient: ServeModelSuggesting?,
        effortClient: ServeReasoningEffortSuggesting? = nil,
        initialFocus: NewSessionField
    ) -> NewSessionSheetModel {
        NewSessionSheetModel(
            presentation: NewSessionSheetPresentation(
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
        try waitForMainQueue("settings model suggestions", until: {
            model.state.rows[0].modelOptions.contains(where: { $0.id == "sonnet" })
        })
        try waitForMainQueueTurn()
        try expect(mutationClient.sentRequests.isEmpty, "resolving options alone must send nothing")

        model.focus(role: "master", field: .model)
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the model select")

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
        try waitForMainQueue("settings model suggestions", until: {
            model.state.rows[0].modelOptions.contains(where: { $0.id == "sonnet" })
        })
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
        try waitForMainQueue("settings model suggestions", until: {
            model.state.rows[0].modelOptions.contains(where: { $0.id == "sonnet" })
        })
        model.focus(role: "master", field: .model)
        try expect(model.handle(try keyEvent("l", keyCode: 37)), "l should cycle the model select")
        try waitForMainQueue("failed role-default save", until: { model.errorMessage != nil })

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
        try waitForMainQueue("settings model suggestions", until: {
            model.state.rows[0].modelOptions.contains(where: { $0.id == "haiku" })
        })
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
        try waitForMainQueue("newer role-default save ack", until: { !model.state.rows[0].isDirty })
        mutationClient.fireCompletion(forRequestAt: 0)
        try waitForMainQueue("older role-default save ack", until: { model.state.rows[0].isDirty })

        try expect(model.errorMessage == nil, "both saves succeeding should leave no error")
    }

    /// A fractional footer height puts every plate border and the snapped terminal edge on half
    /// pixels at 1x, which renders blurry — guards `ActionBarMetrics.plateSvgHeight` against a
    /// future edit reintroducing a fractional sum.
    private static func testActionBarFooterHeightIsIntegral() throws {
        try expect(
            ActionBarMetrics.plateSvgHeight == ActionBarMetrics.plateSvgHeight.rounded(),
            "plateSvgHeight should be a whole point, got \(ActionBarMetrics.plateSvgHeight)"
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
            ActionBarMetrics.barHitRect.minY >= 0 && ActionBarMetrics.barHitRect.maxY <= ActionBarMetrics.plateSvgHeight,
            "bar hit area should sit inside the footer, got \(ActionBarMetrics.barHitRect)"
        )
    }

    /// `hitTest` receives its point in the superview's coordinates. The footer sits a shell gap plus a
    /// row-snap leftover above the window bottom, so a click on a slot's or the plate's top edge must
    /// still reach the footer, and a point in the gap above the plate must not.
    private static func testActionBarHitTestUsesSuperviewCoordinates() throws {
        let superview = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        let footer = ActionBarShellView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        superview.addSubview(footer)
        let rowSnapLeftover: CGFloat = 6
        let bottomInset = ShellMetrics.gap + rowSnapLeftover
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: superview.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: superview.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: superview.bottomAnchor, constant: -bottomInset),
            footer.heightAnchor.constraint(equalToConstant: ActionBarMetrics.plateSvgHeight),
        ])
        superview.layoutSubtreeIfNeeded()

        let plateLeft = (superview.bounds.width - ActionBarMetrics.plateWidth) / 2
        let slotCentreX = plateLeft + ActionBarMetrics.slotX(at: 0) + ActionBarMetrics.slotSize / 2
        let plateTopEdgeY = bottomInset + ActionBarMetrics.plateSvgHeight
        let slotTopEdgeY = plateTopEdgeY - ActionBarMetrics.slotTop - 0.5
        try expect(
            footer.hitTest(NSPoint(x: slotCentreX, y: slotTopEdgeY)) != nil,
            "a click on a slot's top edge should reach the footer"
        )
        try expect(
            footer.hitTest(NSPoint(x: plateLeft + 100, y: plateTopEdgeY - 0.5)) != nil,
            "a click on the plate's top edge should reach the footer"
        )
        try expect(
            footer.hitTest(NSPoint(x: slotCentreX, y: plateTopEdgeY + 1)) == nil,
            "a click in the gap above the plate should fall through the footer"
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

        let window = HeadlessWindow(size: CGSize(width: 300, height: 200))
        window.contentView = scrollView
        window.show()
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
        let window = HeadlessWindow(size: CGSize(width: 300, height: 200))
        window.contentView = scrollView
        window.show()
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
        let window = HeadlessWindow(size: CGSize(width: width, height: height))
        window.contentView = hosting
        window.show()
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
        let window = HeadlessWindow(size: CGSize(width: 300, height: 200))
        window.contentView = hosting
        window.show()
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
        let window = HeadlessWindow(size: CGSize(width: 300, height: 200))
        window.contentView = hosting
        window.show()
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
        let window = HeadlessWindow(size: CGSize(width: 300, height: 200))
        window.contentView = hosting
        window.show()
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

    private static func waitForMainQueue(
        _ description: String,
        timeout: TimeInterval = 10,
        until condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: min(Date().addingTimeInterval(0.01), deadline))
        }
        try expect(condition(), "timed out waiting for \(description) after \(Int(timeout)) seconds")
    }

    private static func waitForMainQueueTurn() throws {
        var didRun = false
        DispatchQueue.main.async {
            didRun = true
        }
        try waitForMainQueue("queued main-thread work", until: { didRun })
    }

    private static func trackerShowsSkeleton(for observedLabel: String) -> Bool {
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.apply(.serveUnavailable(observedLabel))
        return isBackendStartingMessage(snapshot.serviceStateMessage)
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

    /// Monaco ships Regular only. CoreText would hand back Regular for semibold, bold and italic requests, so each
    /// request must fall through to the system mono at the requested weight and style.
    private static func testGhosttyFamilyWithoutSemiboldOrItalicFallsBackToSystemFace() throws {
        try expect(GhosttyFontFamily.face(family: "Monaco", size: 12, weight: .regular, italic: false) != nil, "Monaco should supply its regular face")
        try expect(GhosttyFontFamily.face(family: "Monaco", size: 12, weight: .semibold, italic: false) == nil, "Monaco has no semibold face")
        try expect(GhosttyFontFamily.face(family: "Monaco", size: 12, weight: .bold, italic: false) == nil, "Monaco has no bold face")
        try expect(GhosttyFontFamily.face(family: "Monaco", size: 12, weight: .regular, italic: true) == nil, "Monaco has no italic face")
        for (weight, italic) in [(NSFont.Weight.semibold, false), (.bold, false), (.regular, true)] {
            let font = AppFonts.font(family: "Monaco", size: 12, weight: weight, italic: italic)
            try expect(font.isFixedPitch, "the fallback for weight \(weight.rawValue) italic \(italic) should be monospaced")
            try expect(GhosttyFontFamily.matches(font, weight: weight, italic: italic), "the fallback should keep weight \(weight.rawValue) and italic \(italic)")
        }
    }

    /// Menlo has Bold but no Semibold. CoreText would substitute Bold for a semibold request, which is the wrong weight.
    private static func testMenloSemiboldIsNotSubstitutedWithBold() throws {
        try expect(GhosttyFontFamily.face(family: "Menlo", size: 12, weight: .semibold, italic: false) == nil, "Menlo has no semibold face")
        try expect(GhosttyFontFamily.face(family: "Menlo", size: 12, weight: .bold, italic: false) != nil, "Menlo should supply its bold face")
    }

    private static func testAppFontsUseGhosttyFamilyWhenItHasTheFace() throws {
        let font = AppFonts.font(family: "Menlo", size: 12, weight: .regular, italic: true)
        try expect(font.familyName == "Menlo", "Menlo italic should resolve from Menlo, got \(font.familyName ?? "nil")")
        try expect(GhosttyFontFamily.matches(font, weight: .regular, italic: true), "Menlo italic should keep its italic trait")
    }

    /// Markdown takes the family only when it has regular, semibold and italic faces. Monaco and Menlo lack semibold.
    private static func testMarkdownFamilyNeedsEveryFaceItsThemesUse() throws {
        try expect(GhosttyFontFamily.markdownFamily(for: nil) == .system(.monospaced), "no family should give the system mono")
        try expect(GhosttyFontFamily.markdownFamily(for: "Monaco") == .system(.monospaced), "Monaco has no semibold, so Markdown should use the system mono")
        try expect(GhosttyFontFamily.markdownFamily(for: "Menlo") == .system(.monospaced), "Menlo has no semibold, so Markdown should use the system mono")
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
