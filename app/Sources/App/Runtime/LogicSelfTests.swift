#if DEBUG
import AppKit
import Combine
import Darwin
import Foundation
import ImageIO
import QuestmasterCore
import SwiftUI
import WebKit

@MainActor
enum LogicSelfTests {
    private static let selfTestWaitTimeout: TimeInterval = 10
    private static let socketPollTimeoutMilliseconds: Int32 = 10_000

    private static let cases: [(name: String, body: @MainActor () throws -> Void)] = [
        ("testAppBackendResolverFeedsLaunchConfiguration", testAppBackendResolverFeedsLaunchConfiguration),
        ("testLaunchFlagMappingTable", testLaunchFlagMappingTable),
        ("testDaemonEnsureUsesRespawnPolicy", testDaemonEnsureUsesRespawnPolicy),
        ("testDevBackendBeatsGlobalPathInSourceCheckout", testDevBackendBeatsGlobalPathInSourceCheckout),
        ("testPackagedBundleBeatsDevAndGlobalBackends", testPackagedBundleBeatsDevAndGlobalBackends),
        ("testInstalledBundleStartsTheStableLink", testInstalledBundleStartsTheStableLink),
        ("testBundleWithoutAResolvingStableLinkBootstrapsWithItsQM", testBundleWithoutAResolvingStableLinkBootstrapsWithItsQM),
        ("testAppChildProcessEnvironmentAppliesBackendAfterNormalizedPath", testAppChildProcessEnvironmentAppliesBackendAfterNormalizedPath),
        ("testDaemonRecordFeedsTerminalEnvironment", testDaemonRecordFeedsTerminalEnvironment),
        ("testDaemonRecordReusesTheBinaryHashUntilTheBinaryChanges", testDaemonRecordReusesTheBinaryHashUntilTheBinaryChanges),
        ("testTmuxStartupScriptScopesAppBackendEnvironmentToSession", testTmuxStartupScriptScopesAppBackendEnvironmentToSession),
        ("testTmuxStartupScriptNeverRespawnsPlaceholder", testTmuxStartupScriptNeverRespawnsPlaceholder),
        ("testTmuxStartupScriptTargetsOnlyTheExactSession", testTmuxStartupScriptTargetsOnlyTheExactSession),
        ("testTmuxStartupScriptWritesNoGlobalEnvironment", testTmuxStartupScriptWritesNoGlobalEnvironment),
        ("testTmuxStartupScriptDoesNotStartServer", testTmuxStartupScriptDoesNotStartServer),
        ("testTmuxClientCallsTargetTheExactSession", testTmuxClientCallsTargetTheExactSession),
        ("testStartupScriptPrefixesEveryTmuxCall", testStartupScriptPrefixesEveryTmuxCall),
        ("testStartupScriptNeverCreatesSessions", testStartupScriptNeverCreatesSessions),
        ("testStartupScriptQuotesConfigPaths", testStartupScriptQuotesConfigPaths),
        ("testTmuxClientCallsUseRoute", testTmuxClientCallsUseRoute),
        ("testCrossServerSwitchCreatesSurface", testCrossServerSwitchCreatesSurface),
        ("testSameServerSwitchReusesClient", testSameServerSwitchReusesClient),
        ("testUnknownMethodFailsAttach", testUnknownMethodFailsAttach),
        ("testCachedRouteAttachesBeforeRefresh", testCachedRouteAttachesBeforeRefresh),
        ("testFailedCachedAttachRetriesRefreshedRoute", testFailedCachedAttachRetriesRefreshedRoute),
        ("testFailedCachedAttachRetriesRouteRefreshedFirst", testFailedCachedAttachRetriesRouteRefreshedFirst),
        ("testContinuedSessionFetchesMovedRouteBeforeAttach", testContinuedSessionFetchesMovedRouteBeforeAttach),
        ("testStartupChoiceAcrossServers", testStartupChoiceAcrossServers),
        ("testEditorWindowUsesAttachedRoute", testEditorWindowUsesAttachedRoute),
        ("testNavigationTogglesKeepFocusAndHideToTerminal", testNavigationTogglesKeepFocusAndHideToTerminal),
        ("testDirectionalRegionFocusMapping", testDirectionalRegionFocusMapping),
        ("testKeymapErgonomicsBindings", testKeymapErgonomicsBindings),
        ("testArtifactNavigationPolicy", testArtifactNavigationPolicy),
        ("testArtifactViewerLoadsNothingWhenTheBlockerFailsToCompile", testArtifactViewerLoadsNothingWhenTheBlockerFailsToCompile),
        ("testArtifactViewerLoadsThePageOnceTheBlockerCompiles", testArtifactViewerLoadsThePageOnceTheBlockerCompiles),
        ("testArtifactExternalOpenRouting", testArtifactExternalOpenRouting),
        ("testArtifactEditorWindowKeepsPathSeparate", testArtifactEditorWindowKeepsPathSeparate),
        ("testBoundedProcessDrainsBothPipesPastCapacity", testBoundedProcessDrainsBothPipesPastCapacity),
        ("testBoundedProcessCapsOutput", testBoundedProcessCapsOutput),
        ("testBoundedProcessTimesOutAChildIgnoringTerm", testBoundedProcessTimesOutAChildIgnoringTerm),
        ("testBoundedProcessReapsWithHeldOpenPipe", testBoundedProcessReapsWithHeldOpenPipe),
        ("testConnectReturnsToMainPromptlyWithBlockedRunner", testConnectReturnsToMainPromptlyWithBlockedRunner),
        ("testOutOfOrderConnectsOnlyNewestMutates", testOutOfOrderConnectsOnlyNewestMutates),
        ("testEditorWindowOpensOffMain", testEditorWindowOpensOffMain),
        ("testLoginEnvironmentNeverBlocksUI", testLoginEnvironmentNeverBlocksUI),
        ("testLocalMarkdownImageURLFiltering", testLocalMarkdownImageURLFiltering),
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
        ("testSelectedSessionPanelFadesItsIconInWhenTheSessionChanges", testSelectedSessionPanelFadesItsIconInWhenTheSessionChanges),
        ("testAvatarPoseSwitchesLandAtOnceWithNoImplicitAnimation", testAvatarPoseSwitchesLandAtOnceWithNoImplicitAnimation),
        ("testAvatarEffectLayersKeepTheirPlacement", testAvatarEffectLayersKeepTheirPlacement),
        ("testAFinishPlaysInPlace", testAFinishPlaysInPlace),
        ("testIdleBreathingUsesAuthoredFramesAndLidStencil", testIdleBreathingUsesAuthoredFramesAndLidStencil),
        ("testAnEnterPlaysThenTheLoopStartsFromItsFirstFrame", testAnEnterPlaysThenTheLoopStartsFromItsFirstFrame),
        ("testASteadyPosesFinishPlaysInPlaceOfItsLoop", testASteadyPosesFinishPlaysInPlaceOfItsLoop),
        ("testAReleaseMovesOnItsNamedStrikeFrame", testAReleaseMovesOnItsNamedStrikeFrame),
        ("testALoopingIdleCyclesItsFramesWithNoBreathOrBlink", testALoopingIdleCyclesItsFramesWithNoBreathOrBlink),
        ("testALoopingIdleFrameWithoutArtIsMissing", testALoopingIdleFrameWithoutArtIsMissing),
        ("testAnIdleWithoutLidDataRestOnItsStillFrame", testAnIdleWithoutLidDataRestsOnItsStillFrame),
        ("testTheStageLaunchesEachSpellFromItsPayloads", testTheStageLaunchesEachSpellFromItsPayloads),
        ("testTheFlightOverlaySitsAboveTheTerminalIgnoresHitsAndFliesToThePanelsEdge", testTheFlightOverlaySitsAboveTheTerminalIgnoresHitsAndFliesToThePanelsEdge),
        ("testASpellWithFramesFliesHeadFirstAndPlaysItsImpactOnce", testASpellWithFramesFliesHeadFirstAndPlaysItsImpactOnce),
        ("testASpellFrameWithoutArtIsMissing", testASpellFrameWithoutArtIsMissing),
        ("testAStillThatSaysWhichWayItFacesLeadsWithItsHead", testAStillThatSaysWhichWayItFacesLeadsWithItsHead),
        ("testEveryBundledStillLeadsWithItsHeadOnItsPath", testEveryBundledStillLeadsWithItsHeadOnItsPath),
        ("testBundledBardSpritesReadTheirAnimationFile", testBundledBardSpritesReadTheirAnimationFile),
        ("testBundledWizardSpritesReadTheirAnimationFile", testBundledWizardSpritesReadTheirAnimationFile),
        ("testBundledPaladinSpritesReadTheirAnimationFile", testBundledPaladinSpritesReadTheirAnimationFile),
        ("testBundledDruidSpritesReadTheirAnimationFile", testBundledDruidSpritesReadTheirAnimationFile),
        ("testBundledRogueSpritesReadTheirAnimationFile", testBundledRogueSpritesReadTheirAnimationFile),
        ("testBundledClericSpritesReadTheirAnimationFile", testBundledClericSpritesReadTheirAnimationFile),
        ("testBundledRangerSpritesReadTheirAnimationFile", testBundledRangerSpritesReadTheirAnimationFile),
        ("testBundledNecromancerSpritesReadTheirAnimationFile", testBundledNecromancerSpritesReadTheirAnimationFile),
        ("testBundledSorcererSpritesReadTheirAnimationFile", testBundledSorcererSpritesReadTheirAnimationFile),
        ("testBundledFighterSpritesReadTheirAnimationFile", testBundledFighterSpritesReadTheirAnimationFile),
        ("testAnIdleEffectLayerPlaysOnItsOwnClockThroughFidgets", testAnIdleEffectLayerPlaysOnItsOwnClockThroughFidgets),
        ("testEveryBundledIdleEffectHasItsArtAndLoops", testEveryBundledIdleEffectHasItsArtAndLoops),
        ("testBundledBardSpellsPlayFramesFacingRight", testBundledBardSpellsPlayFramesFacingRight),
        ("testBundledDruidBubbleTailPointsAtHer", testBundledDruidBubbleTailPointsAtHer),
        ("testTheBubbleStaysInTheSlotAboveTheBanner", testTheBubbleStaysInTheSlotAboveTheBanner),
        ("testTallAvatarDrawsOverThePlatesWithoutChangingTheSlot", testTallAvatarDrawsOverThePlatesWithoutChangingTheSlot),
        ("testTheBannerCoversArtBelowTheSoleButKeepsTheSoleVisible", testTheBannerCoversArtBelowTheSoleButKeepsTheSoleVisible),
        ("testTheAvatarStandsOnTheFullWidthBannerAboveTheShells", testTheAvatarStandsOnTheFullWidthBannerAboveTheShells),
        ("testShellsAndNoAttachmentGiveTheAvatarSpaceBackToTheList", testShellsAndNoAttachmentGiveTheAvatarSpaceBackToTheList),
        ("testTheBundledIdleFiguresSetTheSlot", testTheBundledIdleFiguresSetTheSlot),
        ("testMotionTokensShareOneEasingAndFollowReduceMotion", testMotionTokensShareOneEasingAndFollowReduceMotion),
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
        ("testQuestLogListStartsWithItsFirstRowWhole", testQuestLogListStartsWithItsFirstRowWhole),
        ("testQuestLogFilterFieldTakesClicksWhenTheModalIsScaledDown", testQuestLogFilterFieldTakesClicksWhenTheModalIsScaledDown),
        ("testModalEntranceScalesAboutItsCentre", testModalEntranceScalesAboutItsCentre),
        ("testModalEntranceRoutesClicksToWhereItDraws", testModalEntranceRoutesClicksToWhereItDraws),
        ("testModalEntranceIsSkippedUnderReduceMotion", testModalEntranceIsSkippedUnderReduceMotion),
        ("testModalCloseScalesBackAboutItsCentre", testModalCloseScalesBackAboutItsCentre),
        ("testQuestLogOpensWithoutRedrawingTheParchment", testQuestLogOpensWithoutRedrawingTheParchment),
        ("testQuestLogPageScrollsWithTheWheel", testQuestLogPageScrollsWithTheWheel),
        ("testTheTitleFieldsTextStaysPutWhenTheClassSegmentChanges", testTheTitleFieldsTextStaysPutWhenTheClassSegmentChanges),
        ("testEditSessionKeepsItsTitleTextStillWhenControlECyclesTheClass", testEditSessionKeepsItsTitleTextStillWhenControlECyclesTheClass),
        ("testEditRepoReturnSavesTheColour", testEditRepoReturnSavesTheColour),
        ("testDeleteConfirmationReturnConfirmsAndControlBracketCancels", testDeleteConfirmationReturnConfirmsAndControlBracketCancels),
        ("testFilterBarTextSitsOnOneBaselineRestingAndFocused", testFilterBarTextSitsOnOneBaselineRestingAndFocused),
        ("testTextFieldsFitTheirWholeLine", testTextFieldsFitTheirWholeLine),
        ("testRenderedSpacingStaysOnTheScale", testRenderedSpacingStaysOnTheScale),
        ("testChromeShadowsReachPastTheirClips", testChromeShadowsReachPastTheirClips),
        ("testShellRowsKeepTheMocksGeometry", testShellRowsKeepTheMocksGeometry),
        ("testTheShellSectionIsPinnedToTheTrackersBottom", testTheShellSectionIsPinnedToTheTrackersBottom),
        ("testTheShellSectionScrollsInsideItselfPastItsMaxHeight", testTheShellSectionScrollsInsideItselfPastItsMaxHeight),
        ("testFilterFieldFocusFollowsTheFirstResponder", testFilterFieldFocusFollowsTheFirstResponder),
        ("testQuestLogFilterReturnAndEscHandBackToTheList", testQuestLogFilterReturnAndEscHandBackToTheList),
        ("testDockKeepsItsStateAcrossSessionSwitches", testDockKeepsItsStateAcrossSessionSwitches),
        ("testNewArtifactsOpenFromBehindTheWorkerChat", testNewArtifactsOpenFromBehindTheWorkerChat),
        ("testDockPanePublishesModeChanges", testDockPanePublishesModeChanges),
        ("testWatcherDockKeysMoveOpenCopyAndRefresh", testWatcherDockKeysMoveOpenCopyAndRefresh),
        ("testRefreshSpinnerIsTheTrackersSpinnerAndTurnsOnlyInAWindow", testRefreshSpinnerIsTheTrackersSpinnerAndTurnsOnlyInAWindow),
        ("testSkeletonsBreatheByCoreAnimationOnlyInAWindowAndHoldStillUnderReduceMotion", testSkeletonsBreatheByCoreAnimationOnlyInAWindowAndHoldStillUnderReduceMotion),
        ("testEveryEmptyPanelDrawsTheOneIconCentredInItsSection", testEveryEmptyPanelDrawsTheOneIconCentredInItsSection),
        ("testWatcherTitleBarShowsTheSpinnerWhileTheStoreRefreshes", testWatcherTitleBarShowsTheSpinnerWhileTheStoreRefreshes),
        ("testDockColumnLaysOutItsPanels", testDockColumnLaysOutItsPanels),
        ("testOnlyTheFocusedDockPanelHasTheKeys", testOnlyTheFocusedDockPanelHasTheKeys),
        ("testDockPanelsTransitionOnceAndSkipItWithReducedMotion", testDockPanelsTransitionOnceAndSkipItWithReducedMotion),
        ("testCommandKeysReachTheirActionsWhileTheTerminalConsumesKeyEquivalents", testCommandKeysReachTheirActionsWhileTheTerminalConsumesKeyEquivalents),
        ("testDockSelectionPublishesImmediately", testDockSelectionPublishesImmediately),
        ("testArtifactExternalOpenUsesCurrentListAndViewerArtifact", testArtifactExternalOpenUsesCurrentListAndViewerArtifact),
        ("testGChordShortcutIgnoresCapsLock", testGChordShortcutIgnoresCapsLock),
        ("testKeymapPressReadsEventsAsTheKeymapDoes", testKeymapPressReadsEventsAsTheKeymapDoes),
        ("testKeymapPressIgnoresCapsLock", testKeymapPressIgnoresCapsLock),
        ("testArtifactListGChordJumpsToEdgesAndForcesRescroll", testArtifactListGChordJumpsToEdgesAndForcesRescroll),
        ("testListGChordPendingGResetsOnGAndOnInterveningKey", testListGChordPendingGResetsOnGAndOnInterveningKey),
        ("testArtifactListTabsStepWithBrackets", testArtifactListTabsStepWithBrackets),
        ("testTrackerListKeysMoveTheCursor", testTrackerListKeysMoveTheCursor),
        ("testArtifactDockCopiesSelectedArtifactPathWithY", testArtifactDockCopiesSelectedArtifactPathWithY),
        ("testArtifactDockCopiesMultipleSelectedArtifactPathsWithY", testArtifactDockCopiesMultipleSelectedArtifactPathsWithY),
        ("testArtifactDockDeletesSelectedArtifactsWithD", testArtifactDockDeletesSelectedArtifactsWithD),
        ("testArtifactViewerCopiesAndRefreshesWithKeys", testArtifactViewerCopiesAndRefreshesWithKeys),
        ("testArtifactViewerBackKeysReturnToList", testArtifactViewerBackKeysReturnToList),
        ("testSessionCoordinatorRunsSuccessCallbackOnlyAfterAck", testSessionCoordinatorRunsSuccessCallbackOnlyAfterAck),
        ("testEndedIconShowsOnlyWhenTheViewedSessionIsGone", testEndedIconShowsOnlyWhenTheViewedSessionIsGone),
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
        ("testEditQuestTypesFieldListsTheOpenTypesAsSuggestions", testEditQuestTypesFieldListsTheOpenTypesAsSuggestions),
        ("testEditQuestTabReachesTheSizeSelect", testEditQuestTabReachesTheSizeSelect),
        ("testEditQuestSizeSelectCyclesWithHLAndArrows", testEditQuestSizeSelectCyclesWithHLAndArrows),
        ("testEditQuestSizeIsSentOnlyWhenChanged", testEditQuestSizeIsSentOnlyWhenChanged),
        ("testEditQuestTypesReturnAddsOnlyWhileTheQueryMatches", testEditQuestTypesReturnAddsOnlyWhileTheQueryMatches),
        ("testEditQuestReturnWithNoQuerySubmits", testEditQuestReturnWithNoQuerySubmits),
        ("testEditQuestSpaceBackspaceAndETypeInTheTypesField", testEditQuestSpaceBackspaceAndETypeInTheTypesField),
        ("testNewQuestLeavingAndReturningToTheProjectFieldEndsItsSearch", testNewQuestLeavingAndReturningToTheProjectFieldEndsItsSearch),
        ("testNewQuestEscapeClosesWhileSubmitting", testNewQuestEscapeClosesWhileSubmitting),
        ("testNewSessionControlRRefreshesModelsFromTheModelField", testNewSessionControlRRefreshesModelsFromTheModelField),
        ("testNewSessionPathTabTakesTheRowAndDoesNotDrillDown", testNewSessionPathTabTakesTheRowAndDoesNotDrillDown),
        ("testNewSessionPathReturnTakesARowOnlyOnceAnArrowChoseIt", testNewSessionPathReturnTakesARowOnlyOnceAnArrowChoseIt),
        ("testNewSessionPathControlNAndControlPMoveTheRows", testNewSessionPathControlNAndControlPMoveTheRows),
        ("testNewSessionTypingAfterATakeRefreshesTheRows", testNewSessionTypingAfterATakeRefreshesTheRows),
        ("testNewQuestPathTabTakesTheDirectoryAndTheSearchGoesOn", testNewQuestPathTabTakesTheDirectoryAndTheSearchGoesOn),
        ("testNewQuestPathTabMovesOnWhenNothingCompletes", testNewQuestPathTabMovesOnWhenNothingCompletes),
        ("testConnectWithRetryRetriesUntilConnectSucceeds", testConnectWithRetryRetriesUntilConnectSucceeds),
        ("testConnectWithRetryGivesUpAfterExhaustingTheSchedule", testConnectWithRetryGivesUpAfterExhaustingTheSchedule),
        ("testOneShotServeClientsRejectIncompatibleEnvelopes", testOneShotServeClientsRejectIncompatibleEnvelopes),
        ("testServeStreamReconnectsAfterProtocolMismatch", testServeStreamReconnectsAfterProtocolMismatch),
        ("testReadLineReturnsALineSpanningManyReads", testReadLineReturnsALineSpanningManyReads),
        ("testServeStreamJoinsLinesSplitAcrossWrites", testServeStreamJoinsLinesSplitAcrossWrites),
        ("testServeStreamDropsAConnectionWhoseFrameOutgrowsTheCap", testServeStreamDropsAConnectionWhoseFrameOutgrowsTheCap),
        ("testServeStreamStopsReadingAtAMidStreamProtocolMismatch", testServeStreamStopsReadingAtAMidStreamProtocolMismatch),
        ("testServeStreamKeepsTheLastTrackerWhenTheConnectionDrops", testServeStreamKeepsTheLastTrackerWhenTheConnectionDrops),
        ("testServeClientStopEndsAConnectedStream", testServeClientStopEndsAConnectedStream),
        ("testServeClientStopClosesASocketThatConnectsAfterIt", testServeClientStopClosesASocketThatConnectsAfterIt),
        ("testServeClientStopEndsTheRetryWait", testServeClientStopEndsTheRetryWait),
        ("testSocketWriteToAPeerThatHungUpFailsWithoutSIGPIPE", testSocketWriteToAPeerThatHungUpFailsWithoutSIGPIPE),
        ("testSettingsCyclingAFieldSendsItsRoleDefaultImmediately", testSettingsCyclingAFieldSendsItsRoleDefaultImmediately),
        ("testSettingsArrangeMovesAProjectWithShiftJAndK", testSettingsArrangeMovesAProjectWithShiftJAndK),
        ("testTmuxSettingsRendersAtSheetSize", testTmuxSettingsRendersAtSheetSize),
        ("testSettingsCloseDoesNotWaitForInFlightSaves", testSettingsCloseDoesNotWaitForInFlightSaves),
        ("testSettingsFailedSaveSurfacesErrorMessage", testSettingsFailedSaveSurfacesErrorMessage),
        ("testSettingsResendsAnEditMadeWhileAPreviousSaveIsInFlight", testSettingsResendsAnEditMadeWhileAPreviousSaveIsInFlight),
        ("testActionBarHeaderSitsOverTheTerminalColumn", testActionBarHeaderSitsOverTheTerminalColumn),
        ("testActionBarCaffeinateSpinsOnlyWhileOn", testActionBarCaffeinateSpinsOnlyWhileOn),
        ("testActionBarButtonsCentreUnderTheTitlebar", testActionBarButtonsCentreUnderTheTitlebar),
        ("testSpinnerTurnsItsArcUnderAStillRing", testSpinnerTurnsItsArcUnderAStillRing),
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
        ("testAgentLogosAreLoadedOncePerSideAndTint", testAgentLogosAreLoadedOncePerSideAndTint),
        ("testDockPaneRoutesTheWorkerLogFilterKeys", testDockPaneRoutesTheWorkerLogFilterKeys),
        ("testWorkerLogFilterKeepsItsDesignedSize", testWorkerLogFilterKeepsItsDesignedSize),
        ("testDockTopBarClicksEndTheLogFilterExceptOnItsOwnButtons", testDockTopBarClicksEndTheLogFilterExceptOnItsOwnButtons),
        ("testWorkerLogFilterScrollsPastItsMaxHeightAndKeepsTheCursorInView", testWorkerLogFilterScrollsPastItsMaxHeightAndKeepsTheCursorInView),
        ("testWorkerLogFilterFollowsTheBottomPanelsKeys", testWorkerLogFilterFollowsTheBottomPanelsKeys),
        ("testWorkerLogFilterStaysInsideTheBottomPanelBelowWatcher", testWorkerLogFilterStaysInsideTheBottomPanelBelowWatcher),
        ("testWorkerLogChipsStayUnderTheTopBarInEveryState", testWorkerLogChipsStayUnderTheTopBarInEveryState),
        ("testWorkerChatFeedFadesInUnderItsHeader", testWorkerChatFeedFadesInUnderItsHeader),
        ("testWorkerLogChipNamesTheTicksInTheDesignsColoursAndGrowsWithThem", testWorkerLogChipNamesTheTicksInTheDesignsColoursAndGrowsWithThem),
        ("testFilterChipDrawsItsKindInMetaHighlightedAndItsTitleInBody", testFilterChipDrawsItsKindInMetaHighlightedAndItsTitleInBody),
        ("testWorkerLogChipShowsOnlyWhileAMasterIsAttached", testWorkerLogChipShowsOnlyWhileAMasterIsAttached),
        ("testWorkerLogTabsUseTheChatFontAndFiveAroundEachDiamond", testWorkerLogTabsUseTheChatFontAndFiveAroundEachDiamond),
        ("testWorkerLogTabsScrollToTheSelection", testWorkerLogTabsScrollToTheSelection),
        ("testWorkerLogTabsFadeOnlyTheSidesWithHiddenTabs", testWorkerLogTabsFadeOnlyTheSidesWithHiddenTabs),
        ("testWorkerLogTabsSitUnderTheFeedAndNeedTwoWorkers", testWorkerLogTabsSitUnderTheFeedAndNeedTwoWorkers),
        ("testQuestLogTabsCentreWhenTheyFit", testQuestLogTabsCentreWhenTheyFit),
        ("testGhosttyFamilyWithoutSemiboldOrItalicFallsBackToSystemFace", testGhosttyFamilyWithoutSemiboldOrItalicFallsBackToSystemFace),
        ("testMenloSemiboldIsNotSubstitutedWithBold", testMenloSemiboldIsNotSubstitutedWithBold),
        ("testAppFontsUseGhosttyFamilyWhenItHasTheFace", testAppFontsUseGhosttyFamilyWhenItHasTheFace),
        ("testMarkdownFamilyNeedsEveryFaceItsThemesUse", testMarkdownFamilyNeedsEveryFaceItsThemesUse),
    ]

    private static let caseTimeoutSeconds: TimeInterval = 120
    // Keep the grandchild's inherited pipe open long enough to prove the reader returns by process state.
    private static let heldPipeGrandchildLifetime: TimeInterval = 30
    // The 150 ms process deadline plus TERM/KILL and pipe-drain waits leaves about 0.5 s for host scheduling.
    private static let boundedProcessTimeoutWatchdog: TimeInterval = 1.5

    static func runIfRequested() -> Bool {
        guard CommandLine.arguments.contains("--run-logic-tests") else {
            return false
        }

        guard !cases.isEmpty else {
            fputs("Questmaster self-tests failed: no test cases registered\n", stderr)
            exit(1)
        }

        // Cases run as if Reduce Motion is off whatever the machine says; the ones that test it set it themselves.
        Motion.reducesMotion = { false }
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

        let tag = SelectedSessionPanelContent.make(currentTerminalSessionID: "shell-second", tracker: tracker)
        try expect(tag.id == "shell-second" && tag.projectName == "Repo", "the tag should name an attached shell's repo, got \(tag.id) / \(tag.projectName)")
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
        let now = Date(timeIntervalSinceReferenceDate: 1_800_000_000)
        let bash = TrackerCast(tool: "Bash", startedAt: now.addingTimeInterval(-2), typicalMS: 6000)

        let outside = TrackerPortraitStatusNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        outside.now = { now }
        outside.configure(geometry: geometry, color: AppPalette.accent, ring: .filling(bash), reduceMotion: false)
        try expect(outside.fillAnimation == nil && outside.pulseAnimation == nil, "a ring outside a window should not animate")

        let status = TrackerPortraitStatusNSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        status.now = { now }
        window.contentView = status
        status.configure(geometry: geometry, color: AppPalette.trackerBlocked, ring: .steady, reduceMotion: false)
        try expect(status.fillAnimation == nil && status.spinAnimation == nil && status.pulseAnimation == nil, "a steady ring should not move")

        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        guard let spin = status.spinAnimation else { throw TestFailure("working with no tool should spin the ring") }
        try expect(spin.duration == WorkingSpinner.period && spin.repeatCount == .infinity, "the spinner should orbit once every 1.2s, for good")

        status.configure(geometry: geometry, color: AppPalette.accent, ring: .filling(bash), reduceMotion: false)
        guard let fill = status.fillAnimation, let pulse = status.pulseAnimation else { throw TestFailure("a cast with a learned duration should fill the ring, then pulse") }
        try expect(abs(fill.duration - 4) < 0.1 && (fill.toValue as? CGFloat) == 1, "2s into a 6s tool the ring should fill to full in 4s, got \(fill.duration)")
        try expect(abs(pulse.beginTime - fill.beginTime - fill.duration) < 0.01, "the pulse should start when the ring is full")
        try expect(pulse.timingFunction === Motion.breathingTimingFunction, "the ring's pulse should breathe on the breathing easing")
        try expect(status.spinAnimation == nil, "a filling ring should not spin")

        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        try expect(status.flashAnimation != nil && status.spinAnimation != nil, "an ended cast should flash, then spin while still working")
        try expect(status.flashAnimation?.duration == MotionStep.standard.seconds * Motion.slowdown, "the flash should fade over a standard step, got \(String(describing: status.flashAnimation?.duration))")
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
        try expect(status.exitAnimation == nil, "under reduce motion the ring should just go, with no exit")

        // Leaving work: the ring completes, flashes and fades into no ring; into a steady status it crossfades.
        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        try expect(status.exitAnimation == nil, "a working ring should not be exiting")
        status.configure(geometry: geometry, color: AppPalette.trackerDone, ring: .none, finishColor: AppPalette.trackerDone, reduceMotion: false)
        guard let exit = status.exitAnimation as? CAKeyframeAnimation else { throw TestFailure("a ring that stops working should play its exit") }
        let step = MotionStep.standard.seconds * Motion.slowdown
        try expect(abs(exit.duration - 3 * step) < 0.01, "the exit should sweep, flash and fade a standard step each, \(3 * step)s, got \(exit.duration)")
        let heldUntil = exit.keyTimes?.dropFirst().first?.doubleValue ?? 0
        try expect(abs(heldUntil - 2.0 / 3) < 0.01, "the ring should stay up through the sweep and the flash, then fade, got \(String(describing: exit.keyTimes))")
        try expect(status.spinAnimation == nil, "the spinner should stop as the ring exits")
        status.configure(geometry: geometry, color: AppPalette.trackerBlocked, ring: .steady, reduceMotion: false)
        try expect(status.exitAnimation == nil, "a ring with nothing to exit from should not play the exit")
        status.configure(geometry: geometry, color: AppPalette.accent, ring: .spinning(nil), reduceMotion: false)
        status.configure(geometry: geometry, color: AppPalette.trackerBlocked, ring: .steady, reduceMotion: false)
        try expect(status.layer?.animation(forKey: kCATransition)?.duration == step, "working into a steady status should crossfade over a standard step")

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
        held.configure(path: CGPath(rect: CGRect(x: 0, y: 0, width: 40, height: 40), transform: nil), color: AppPalette.text)
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
            try expect(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return control() != nil && unconfigured() == 0
            }, "\(description): status views should mount and configure")
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

        /// The first plate starts at the tracker header inset; each following row adds its height and a gap.
        let masterTop = TrackerHeaderAlignmentMetrics.firstSectionTopInset(cellHeight: 0)
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
                try expect(waitUntil {
                    guard let documentView = descendant(NSScrollView.self, in: view)?.documentView else {
                        return false
                    }
                    return documentView.bounds.width > 0 && documentView.bounds.height > 0
                }, "the tracker should finish laying out before its attached dot is measured")
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
        // 0-50, the worker's 20-60.
        try expectRect(master.discEdge.offsetBy(dx: 0, dy: -TrackerPlateDesign.svgDiscInset), 0, 0, 50, 50, "master disc in its row")
        try expectRect(worker.discEdge.offsetBy(dx: 0, dy: -TrackerPlateDesign.svgDiscInset), 20, 0, 60, 40, "worker disc in its row")
        try expectClose(TrackerNameplateRole.topLevelTextX, 55, "master text column")
        try expectClose(TrackerNameplateRole.workerTextX, 65, "worker text column")
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
        try expectClose(TrackerHeaderAlignmentMetrics.firstSectionTopInset(cellHeight: 0), 0, "first section starts at the tracker top")
        try expectClose(TrackerListMetrics.avatarClearance, 40, "clearance between the list and the avatar slot")
        try expectClose(SelectedSessionTagMetrics.width, 260, "banner matches a master plate's width")
        try expectClose(SelectedSessionTagMetrics.tabInset, 5, "id tab inset on each side")
        try expectClose(TrackerListMetrics.contentWidth, TrackerPlateDesign.topLevelSize.width + TrackerPlateDesign.glowBandWidth, "tracker content width, the master plate's and its band's")

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
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for second in 1...4 {
            clock.tick(at: now.addingTimeInterval(TimeInterval(second)))
        }
        try expect(clock.ticks == 4, "the shared clock should deliver each tick once, got \(clock.ticks)")
        try expect(clock.time == now.addingTimeInterval(4).timeIntervalSinceReferenceDate, "the clock should retain the latest tick time")
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
        try pumpOneMainRunLoopTurn()
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
        let now = Date(timeIntervalSinceReferenceDate: 1_800_000_000)
        let started = now.addingTimeInterval(-2)
        let bash = TrackerCast(tool: "Bash", startedAt: started, typicalMS: 6000)
        let overrun = TrackerCast(tool: "Bash", startedAt: now.addingTimeInterval(-9), typicalMS: 6000)
        let mcp = TrackerCast(tool: "mcp__linear__save_issue", startedAt: started, typicalMS: 0)

        let outside = TrackerCastFillNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 13))
        outside.now = { now }
        outside.configure(cast: bash, isFinishing: false, reduceMotion: false)
        try expect(outside.fillAnimation == nil && outside.pulseAnimation == nil, "a bar outside a window should not animate")

        let fill = TrackerCastFillNSView(frame: NSRect(x: 0, y: 0, width: 200, height: 13))
        fill.now = { now }
        window.contentView = fill
        fill.configure(cast: bash, isFinishing: false, reduceMotion: false)
        guard let animation = fill.fillAnimation, let pulse = fill.pulseAnimation else {
            throw TestFailure("a cast with a learned duration should fill, then pulse")
        }
        try expect(abs(animation.duration - 4) < 0.1, "2s into a 6s tool the fill should run 4s to full, got \(animation.duration)")
        try expect(abs(pulse.beginTime - animation.beginTime - animation.duration) < 0.01, "the pulse should start when the bar is full")
        try expect(pulse.repeatCount == .infinity && pulse.autoreverses, "the pulse should breathe until the tool ends")
        try expect(pulse.timingFunction === Motion.breathingTimingFunction, "the bar's pulse should breathe on the breathing easing")
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
        let size = SelectedSessionPanel.canvasSize
        let scale: CGFloat = 2
        // A real window, not `ImageRenderer`, which can't draw the panel's icon layers (they host their own views).
        let window = HeadlessWindow(size: size, scale: scale)
        defer { window.close() }
        let view = NSHostingView(rootView: SelectedSessionPanel(content: content, onCopyID: { _ in }))
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.show()
        func pixel(_ bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> NSColor? {
            bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB)
        }
        var bitmap = try snapshot(view, size: size, scale: scale)
        try expect(waitUntil {
            if let next = try? snapshot(view, size: size, scale: scale) {
                bitmap = next
            }
            return (pixel(bitmap, 258.5, 24.5)?.alphaComponent ?? 0) > 0.9
        }, "the panel should draw its frame")
        try expect(bitmap.pixelsWide == 520 && bitmap.pixelsHigh == 150, "the panel should render 260 x 75 at 2x, got \(bitmap.pixelsWide) x \(bitmap.pixelsHigh)")
        guard let arc = pixel(bitmap, 258.5, 24.5), let outside = pixel(bitmap, 259.5, 22),
              let frame = AppPalette.lineSoftSubtle.usingColorSpace(.sRGB) else {
            throw TestFailure("the corner pixels should be readable")
        }
        func isFrameColour(_ color: NSColor) -> Bool {
            color.alphaComponent > 0.9
                && abs(color.redComponent - frame.redComponent) < 0.02
                && abs(color.greenComponent - frame.greenComponent) < 0.02
                && abs(color.blueComponent - frame.blueComponent) < 0.02
        }
        try expect(outside.alphaComponent < 0.1, "outside the frame's corner should be clear, got alpha \(outside.alphaComponent)")
        try expect(isFrameColour(arc), "the frame's arc at its top-right corner should be the frame's colour, got \(arc)")
        guard let bottomArc = pixel(bitmap, 258.5, 65) else {
            throw TestFailure("the bottom-right pixel should be readable")
        }
        try expect(isFrameColour(bottomArc), "the frame's arc at its bottom-right corner should be the frame's colour, got \(bottomArc)")
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

    /// The disc's icon (a class portrait, or a shell's glyph) fades in when the attached session (or its portrait) changes, in
    /// Core Animation: one opacity animation on the icon's own layer, from clear to full over the standard step on the shared
    /// easing, run once by the render server with the views left in place (the icon is neither re-created nor redrawn for it).
    /// Exactly one fade runs when an icon comes in; none when the disc goes to, or stays, empty. The first icon, an edit that
    /// leaves the session and its portrait alone, a view outside a window and Reduce Motion show no fade. The disc's pixels
    /// are the model layers', which the fade leaves alone: the new icon is in them when the fade starts and they end as drawn
    /// fresh.
    private static func testSelectedSessionPanelFadesItsIconInWhenTheSessionChanges() throws {
        defer { Motion.reducesMotion = { false } }
        Motion.reducesMotion = { false }
        func content(id: String, title: String = "Fix bug", portrait: SessionPortrait? = nil, isShell: Bool = false) -> SelectedSessionPanelContent {
            SelectedSessionPanelContent(title: title, id: id, projectName: "Preview", projectColor: AppPalette.accent, portrait: portrait, isShell: isShell)
        }
        func views(under view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views(under: $0) } }
        func icons(in view: NSView) -> [IconFadeView] { views(under: view).compactMap { $0 as? IconFadeView } }
        func fades(in view: NSView) -> [CABasicAnimation] { icons(in: view).compactMap(\.fadeAnimation) }
        /// The clearest an animating icon layer is right now, as Core Animation shows it: 1 when none is animating.
        func shownOpacity(in view: NSView) -> Float {
            icons(in: view).filter { $0.fadeAnimation != nil }.compactMap { $0.layer?.presentation()?.opacity }.min() ?? 1
        }
        func host(_ initial: SelectedSessionPanelContent) throws -> (model: SelectedSessionPanelFadeModel, view: NSView, window: HeadlessWindow) {
            let model = SelectedSessionPanelFadeModel(initial)
            let size = SelectedSessionPanel.canvasSize
            let window = HeadlessWindow(size: size)
            let view = NSHostingView(rootView: SelectedSessionPanelFadeHarness(model: model))
            view.frame = NSRect(origin: .zero, size: size)
            window.contentView = view
            window.show()
            try expect(waitUntil { icons(in: view).count == 1 }, "the panel should mount its one icon layer")
            return (model, view, window)
        }
        /// The bytes of the disc's square, 64 across, from the panel's top left.
        func disc(_ view: NSView) throws -> [UInt8] {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds), let data = rep.bitmapData else {
                throw TestFailure("the panel should render to a bitmap")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            let side = Int(64 * scale)
            let origin = Int(6 * scale)
            var bytes: [UInt8] = []
            for row in origin..<(origin + side) {
                let start = row * rep.bytesPerRow + origin * rep.samplesPerPixel
                bytes.append(contentsOf: UnsafeBufferPointer(start: data + start, count: side * rep.samplesPerPixel))
            }
            return bytes
        }
        /// The disc once its portrait has drawn: a portrait has far more shades than the bare disc.
        let portraitShades = 100
        func drawnDisc(_ view: NSView) throws -> [UInt8] {
            var bytes: [UInt8] = []
            try expect(waitUntil {
                bytes = (try? disc(view)) ?? []
                return Set(bytes).count > portraitShades
            }, "the portrait should draw")
            return bytes
        }
        func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
            Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(max(1, a.count))
        }
        func isDrawnAs(_ view: NSView, _ settled: [UInt8]) -> Bool {
            (try? disc(view)).map { distance($0, settled) < 1.5 } ?? false
        }

        let paladin = content(id: "qm-a", portrait: .master(.paladin))
        let wizard = content(id: "qm-b", portrait: .master(.wizard))
        let shell = content(id: "qm-c", isShell: true)
        let otherShell = content(id: "qm-d", isShell: true)
        let empty = content(id: "qm-e")
        let otherEmpty = content(id: "qm-f")
        let fresh = try host(wizard)
        defer { fresh.window.close() }
        let wizardSettled = try drawnDisc(fresh.view)

        let (model, view, window) = try host(paladin)
        defer { window.close() }
        let paladinSettled = try drawnDisc(view)
        try expect(distance(paladinSettled, wizardSettled) > 5, "the two classes should draw differently, got \(distance(paladinSettled, wizardSettled))")
        try expect(fades(in: view).isEmpty, "the first icon should not fade in")
        let mounted = views(under: view).map(ObjectIdentifier.init)

        /// Switches to `next` from a clean slate (a finished fade stays on its layer until Core Animation's next commit) and
        /// returns how many icon layers have an installed fade.
        func fadeCount(after next: SelectedSessionPanelContent, _ what: String) throws -> Int {
            icons(in: view).forEach { $0.layer?.removeAllAnimations() }
            model.content = next
            // The presentation layer can be absent until Core Animation commits its first frame; the installed animation is stable evidence.
            try expect(waitUntil { fades(in: view).count == 1 }, "\(what) should install one fade on its icon layer")
            return fades(in: view).count
        }
        /// Switches to `next` from a clean slate and, once `landed`, expects nothing to fade.
        func expectNoFade(after next: SelectedSessionPanelContent, landed: () -> Bool, _ what: String) throws {
            icons(in: view).forEach { $0.layer?.removeAllAnimations() }
            model.content = next
            try expect(waitUntil(landed), "\(what) should land")
            try pumpOneMainRunLoopTurn()
            try expect(fades(in: view).isEmpty, "\(what) shouldn't fade")
        }

        // A new session's class: its portrait, and only that, comes in from clear on its layer.
        try expect(try fadeCount(after: wizard, "a class after a class") == 1, "a class-to-class switch should fade one icon")
        let running = fades(in: view)
        try expect(
            running.allSatisfy {
                $0.keyPath == "opacity" && $0.fromValue as? Double == 0 && $0.toValue as? Double == 1
                    && $0.duration == Motion.duration(.standard) && $0.repeatCount == 0 && !$0.autoreverses
                    && $0.timingFunction === Motion.timingFunction
            },
            "it is one Core Animation opacity fade from clear to full over the standard step, once, on the shared easing"
        )
        try expect(waitUntil { shownOpacity(in: view) == 1 }, "the fade should end on its own, on full opacity")
        try expect(icons(in: view).allSatisfy { $0.layer?.opacity == 1 }, "and leave the icon layer fully opaque")
        try expect(views(under: view).map(ObjectIdentifier.init) == mounted, "the icon's views should be the same ones, not re-created")
        try expect(waitUntil { isDrawnAs(view, wizardSettled) }, "the fade should end on the new icon as drawn fresh")

        // The same session and portrait with a new title: no fade.
        try expectNoFade(after: content(id: "qm-b", title: "Another title", portrait: .master(.wizard)), landed: { true }, "an edit to the same session")

        // A shell's glyph fades in as a class's portrait does, one fade a switch; so does the portrait after it.
        try expect(try fadeCount(after: shell, "a shell after a class") == 1, "a class-to-shell switch should fade one icon")
        try expect(waitUntil { shownOpacity(in: view) == 1 }, "the glyph's fade should end on its own")
        try expect(waitUntil { !isDrawnAs(view, wizardSettled) }, "the glyph should replace the portrait")
        try expect(try fadeCount(after: otherShell, "another shell") == 1, "a shell-to-shell switch should fade one icon")
        try expect(waitUntil { shownOpacity(in: view) == 1 }, "the second glyph's fade should end on its own")
        try expect(try fadeCount(after: paladin, "a class after a shell") == 1, "a shell-to-class switch should fade one icon")
        try expect(waitUntil { shownOpacity(in: view) == 1 }, "the portrait's fade should end on its own")
        try expect(waitUntil { isDrawnAs(view, paladinSettled) }, "the class's portrait should end as drawn fresh")

        // An empty disc (no class, or nothing attached) has no icon to fade: going to it drops the old icon at once, and
        // going from it to another empty disc changes nothing. A class after it fades in.
        try expectNoFade(after: empty, landed: { !isDrawnAs(view, paladinSettled) }, "a class-to-empty-disc switch")
        try expectNoFade(after: otherEmpty, landed: { true }, "an empty-disc-to-empty-disc switch")
        try expect(try fadeCount(after: wizard, "a class after an empty disc") == 1, "an empty-disc-to-class switch should fade one icon")
        try expect(waitUntil { shownOpacity(in: view) == 1 }, "the portrait's fade should end on its own")
        try expect(views(under: view).map(ObjectIdentifier.init) == mounted, "no switch should re-create the icon's views")
        try expect(waitUntil { isDrawnAs(view, wizardSettled) }, "the class's portrait should end as drawn fresh")

        // An icon still fading in when the disc goes empty: the fade goes with the icon. Nothing is cleared by hand after the
        // switch (`expectNoFade` would), so only the view can have dropped it.
        try expect(try fadeCount(after: paladin, "a class before an empty disc") == 1, "a class after a class should fade one icon")
        model.content = empty
        try expect(waitUntil { fades(in: view).isEmpty }, "a switch to an empty disc should drop the fade still running")

        // Reduce Motion: the new icon is there at once, with nothing to run.
        icons(in: view).forEach { $0.layer?.removeAllAnimations() }
        Motion.reducesMotion = { true }
        model.content = paladin
        try expect(waitUntil { isDrawnAs(view, paladinSettled) }, "under Reduce Motion the icon should land")
        try expect(fades(in: view).isEmpty, "under Reduce Motion the icon should land with no fade")

        // The view itself: nothing to fade outside a window, on the first key, the same key or an empty key (nothing to show);
        // leaving the window ends a fade, and any update under Reduce Motion drops one still running.
        Motion.reducesMotion = { false }
        let loose = IconFadeView(rootView: AnyView(Color.clear))
        loose.configure(rootView: AnyView(Color.clear), key: "a")
        loose.configure(rootView: AnyView(Color.clear), key: "b")
        try expect(loose.fadeAnimation == nil, "a view outside a window has nothing to fade")
        let looseWindow = HeadlessWindow(size: SelectedSessionPanel.canvasSize)
        defer { looseWindow.close() }
        let container = NSView(frame: NSRect(origin: .zero, size: SelectedSessionPanel.canvasSize))
        looseWindow.contentView = container
        container.addSubview(loose)
        loose.configure(rootView: AnyView(Color.clear), key: "b")
        try expect(loose.fadeAnimation == nil, "the same key shouldn't fade")
        loose.configure(rootView: AnyView(Color.clear), key: "")
        try expect(loose.fadeAnimation == nil, "an empty key is nothing to show and shouldn't fade")
        loose.configure(rootView: AnyView(Color.clear), key: "c")
        try expect(loose.fadeAnimation != nil, "a new key in a window, after an empty one, should fade")
        loose.removeFromSuperview()
        try expect(loose.fadeAnimation == nil, "a view removed from its window mid-fade should have no fade left")
        container.addSubview(loose)
        try expect(loose.fadeAnimation == nil, "and a remount shouldn't bring one back")
        loose.configure(rootView: AnyView(Color.clear), key: "d")
        try expect(loose.fadeAnimation != nil, "a new key after the remount should fade again")
        loose.configure(rootView: AnyView(Color.clear), key: "")
        try expect(loose.fadeAnimation == nil, "a switch to an empty key mid-fade should drop the fade, though it starts none")
        loose.configure(rootView: AnyView(Color.clear), key: "e")
        try expect(loose.fadeAnimation != nil, "a key after an empty one should fade")
        Motion.reducesMotion = { true }
        loose.configure(rootView: AnyView(Color.clear), key: "e")
        try expect(loose.fadeAnimation == nil, "an update with the same key under Reduce Motion should drop a fade still running")
    }

    /// A pose switch lands at once. Core Animation animates an implicit change to a layer's contents, position, bounds or
    /// hidden state, so an implicit change shows up as a key on the rig's layer that the rig didn't add itself.
    @MainActor
    private static func testAvatarPoseSwitchesLandAtOnceWithNoImplicitAnimation() throws {
        defer { Motion.reducesMotion = { false } }
        let nextTick: TimeInterval = 0.05
        let size = CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        let window = HeadlessWindow(size: size)
        let avatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        avatar.sprites = try stillIdleSprites()
        window.contentView = avatar
        window.show()
        let ownKeys: Set<String> = [TrackerAvatarMotionKey.frames, TrackerAvatarMotionKey.move]
        /// The layer and every layer drawn inside it, so an implicit animation on a child shows up too.
        func tree(_ layer: CALayer) -> [CALayer] {
            [layer] + (layer.sublayers ?? []).flatMap { tree($0) }
        }
        let switches: [(TrackerAvatarPose, Int?)] = [
            (.channelling, nil), (.release, nil), (.idle, nil), (.pondering, nil), (.summoning, nil), (.bow, nil),
            (.callingOut, nil), (.catching, nil), (.studying, nil), (.idle, 2), (.idle, nil),
        ]
        for reduceMotion in [false, true] {
            Motion.reducesMotion = { reduceMotion }
            for (pose, fidget) in switches {
                avatar.configure(pose: pose, fidget: fidget, beat: 0, finish: nil, reduceMotion: reduceMotion)
                RunLoop.current.run(until: Date().addingTimeInterval(nextTick))
                let shown = (avatar.layer?.sublayers ?? []).filter { !$0.isHidden }
                try expect(shown.count == 1, "a switch to \(pose) should show one rig, got \(shown.count)")
                guard let layer = shown.first else {
                    continue
                }
                for part in tree(layer) {
                    let implicit = (part.animationKeys() ?? []).filter { !ownKeys.contains($0) }
                    try expect(implicit.isEmpty, "a switch to \(pose) should land at once, but \(implicit.sorted()) animate implicitly (reduce motion \(reduceMotion))")
                }
                let presented = layer.presentation() ?? layer
                try expect(presented.bounds == layer.bounds && presented.opacity == layer.opacity,
                           "a switch to \(pose) should show its model values on the next tick")
            }
        }
    }

    /// An effect drawn behind the figure sits on the root, under it, and stays put when it moves; an effect in front sits in the
    /// figure, so the figure's move carries it. The figure and both effects play the one-shot's frames together. A
    /// synthetic class's 1-frame character and 8-frame front loop each on their own clock, not the other's.
    @MainActor
    private static func testAvatarEffectLayersKeepTheirPlacement() throws {
        let folder = try syntheticClassFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let sprites = TrackerAvatarSprites(classID: "synthetic", folder: folder) else {
            throw TestFailure("the synthetic class's animation.json should read")
        }
        guard let summoningPlacement = sprites.animation.animation(for: .summoning),
              let callingPlacement = sprites.animation.animation(for: .callingOut),
              let summoning = TrackerAvatarFrameRig(pose: .summoning, placement: summoningPlacement, sprites: sprites),
              let calling = TrackerAvatarFrameRig(pose: .callingOut, placement: callingPlacement, sprites: sprites) else {
            throw TestFailure("the synthetic class's summoning and calling out should both draw")
        }
        summoning.place(in: CGRect(x: 0, y: 0, width: 260, height: 160))
        try expect(summoning.root.sublayers?.first === summoning.behind && summoning.root.sublayers?.dropFirst().first === summoning.figure,
                   "the ground circle should draw under the figure, on the root, with the bubble above both")
        try expect(summoning.figure.sublayers?.first === summoning.character, "the character should be the figure's first layer")
        summoning.startMotion()
        try expect(summoning.figure.animation(forKey: TrackerAvatarMotionKey.move) == nil, "the summoning should not move: its feet stay on the baseline")
        for layer in [summoning.character, summoning.behind] {
            try expect(layer.animation(forKey: TrackerAvatarMotionKey.frames) != nil, "every layer should play the one-shot's frames")
        }
        summoning.stopMotion()
        try expect(summoning.figure.animation(forKey: TrackerAvatarMotionKey.move) == nil && summoning.character.animation(forKey: TrackerAvatarMotionKey.frames) == nil,
                   "stopping should remove the move and the frames")

        calling.place(in: CGRect(x: 0, y: 0, width: 260, height: 160))
        try expect(calling.figure.sublayers?.last === calling.front, "the bubble should draw in front of the character, inside the figure")
        calling.startMotion()
        try expect(calling.figure.animation(forKey: TrackerAvatarMotionKey.move) == nil, "calling out should not bob: its feet stay on the baseline")
        let character = calling.character.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation
        let front = calling.front.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation
        try expect(character?.duration == 0.25 && character?.values?.count == 2, "a 1-frame character should cycle on its own 0.25 s clock")
        try expect(front?.duration == 1 && front?.values?.count == 9, "an 8-frame front should cycle on its own 1 s clock")
    }

    /// A cast's finish plays in place: its frames show, and the figure never leaves its anchor.
    @MainActor
    private static func testAFinishPlaysInPlace() throws {
        let sprites = try stillIdleSprites()
        guard let placement = sprites.animation.animation(for: .studying),
              let rig = TrackerAvatarFrameRig(pose: .studying, placement: placement, sprites: sprites) else {
            throw TestFailure("the wizard's studying should draw")
        }
        rig.place(in: CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight))
        rig.showFinish(elapsed: 0)
        try expect(rig.character.contents != nil, "a finish should show its first frame")
        try expect(rig.figure.animation(forKey: TrackerAvatarMotionKey.move) == nil, "a finish should not move the figure")
    }

    /// The authored breathing images cycle in their explicit order, and a matching lid-content loop carries the recorded pixels.
    @MainActor
    private static func testIdleBreathingUsesAuthoredFramesAndLidStencil() throws {
        defer { Motion.reducesMotion = { false } }
        let folder = try syntheticBreathingIdleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let sprites = TrackerAvatarSprites(classID: "synthetic", folder: folder), let breathingArt = sprites.idleBreathingArt else {
            throw TestFailure("the synthetic breathing track should have every image and lid stencil")
        }
        let size = CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        let window = HeadlessWindow(size: size)
        let avatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        avatar.sprites = sprites
        window.contentView = avatar
        window.show()
        Motion.reducesMotion = { false }
        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        guard let root = (avatar.layer?.sublayers ?? []).first(where: { !$0.isHidden }),
              let character = root.sublayers?.first,
              let lids = root.sublayers?.first(where: { $0.name == TrackerAvatarMotionKey.lids }),
              let animation = character.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation,
              let lidAnimation = lids.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation else {
            throw TestFailure("idle should animate both the authored character frames and lid stencils")
        }
        try expect(animation.calculationMode == .discrete && animation.repeatCount == .infinity,
                   "authored breathing should be a continuous discrete frame loop")
        try expect(animation.values?.count == breathingArt.count + 1 && sameImage(animation.values?.first, breathingArt[0].image)
                   && sameImage(animation.values?.last, breathingArt[0].image),
                   "breathing should start at resume_frame and close on it")
        try expect(lidAnimation.values?.count == breathingArt.count + 1 && sameImage(lidAnimation.values?.first, breathingArt[0].lids),
                   "the full recorded lid stencil should advance with the same frame order")
        try expect(abs(animation.duration - 0.6 * Motion.slowdown) < 1e-9 && abs(lidAnimation.duration - animation.duration) < 1e-9,
                   "the breathing and lid tracks should share the authored period")
        avatar.showEyelids(true)
        try expect(lids.opacity == 1, "the forced blink should show the authored lid image")

        avatar.configure(pose: .studying, beat: 0, finish: nil, reduceMotion: false)
        try expect(character.animation(forKey: TrackerAvatarMotionKey.frames) == nil && lids.animation(forKey: TrackerAvatarMotionKey.frames) == nil,
                   "another pose should suspend breathing and its blink stencil")
        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        let resumed = (avatar.layer?.sublayers ?? []).first(where: { !$0.isHidden })?.sublayers?.first
        let resumedAnimation = resumed?.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation
        try expect(sameImage(resumedAnimation?.values?.first, breathingArt[0].image), "idle should resume at resume_frame after a pose")
        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: true)
        try expect(resumed?.animation(forKey: TrackerAvatarMotionKey.frames) == nil && sameImage(resumed?.contents, sprites.idleFrame(1)),
                   "Reduce Motion should rest on idle f1 without a code-breathing fallback")
    }

    /// A temporary sprite folder with sparse authored idle files and a multi-row blink stencil, used by the view self-tests.
    @MainActor
    private static func syntheticBreathingIdleFolder() throws -> URL {
        let folder = try syntheticClassFolder()
        let file = folder.appendingPathComponent("animation.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              var idle = json["idle"] as? [String: Any] else {
            throw TestFailure("the synthetic class's animation.json should read as an object with idle data")
        }
        idle["blink"] = true
        idle["breathing"] = [
            "resume_frame": "01-idle-breath-f8.png",
            "frames": [
                ["file": "01-idle-breath-f1.png", "seconds": 0.2, "lid_pixels": [[4, 5], [4, 6]]],
                ["file": "01-idle-breath-f3.png", "seconds": 0.2, "lid_pixels": [[8, 9], [9, 9], [9, 10]]],
                ["file": "01-idle-breath-f8.png", "seconds": 0.2, "lid_pixels": [[11, 12], [12, 12]]],
            ],
        ]
        json["idle"] = idle
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        try writeSolidFrame(0.1, width: 64, height: 170, to: folder.appendingPathComponent("01-idle-f1.png"))
        for (index, number) in [1, 3, 8].enumerated() {
            try writeSolidFrame(Double(index + 1) / 10, width: 64, height: 170,
                                to: folder.appendingPathComponent("01-idle-breath-f\(number).png"))
        }
        return folder
    }

    /// A pose's enter shows its own frame as the pose comes on screen, then the loop starts from its first frame. Reduce Motion skips
    /// the enter. The check reads the layer's contents and the loop's keyframes, which hold the sprites' own images.
    @MainActor
    private static func testAnEnterPlaysThenTheLoopStartsFromItsFirstFrame() throws {
        let folder = try syntheticClassFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let sprites = TrackerAvatarSprites(classID: "synthetic", folder: folder) else {
            throw TestFailure("the synthetic class's animation.json should read")
        }
        let size = CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        let window = HeadlessWindow(size: size)
        let avatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        avatar.sprites = sprites
        window.contentView = avatar
        window.show()
        Motion.reducesMotion = { false }
        avatar.configure(pose: .callingOut, beat: 0, finish: nil, enter: 0, reduceMotion: false)
        guard let character = shownCharacter(of: avatar) else {
            throw TestFailure("calling out should draw its character")
        }
        let enterFrame = sprites.frame(.callingOut, .character, 2)
        let loopFrame = sprites.frame(.callingOut, .character, 1)
        try expect(sameImage(character.contents, enterFrame), "an enter should show its own frame as the pose comes on screen")
        avatar.configure(pose: .callingOut, beat: 0, finish: nil, enter: 0.1, reduceMotion: false)
        try expect(sameImage(character.contents, enterFrame), "an enter should hold its frame until the director moves it on")
        avatar.configure(pose: .callingOut, beat: 0, finish: nil, reduceMotion: false)
        let loop = character.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation
        try expect(sameImage(loop?.values?.first, loopFrame), "once the enter has run, the loop should start from its own first frame")
        avatar.configure(pose: .callingOut, beat: 0, finish: nil, enter: 0, reduceMotion: true)
        try expect(sameImage(character.contents, loopFrame), "under Reduce Motion the enter should be skipped")
    }

    /// A steady pose that isn't a cast plays its finish like a cast: the finish's frame shows in place of the loop, which doesn't run
    /// under it, and the loop starts again from its first frame once the finish is over. Reduce Motion skips the finish.
    @MainActor
    private static func testASteadyPosesFinishPlaysInPlaceOfItsLoop() throws {
        let folder = try syntheticClassFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let sprites = TrackerAvatarSprites(classID: "synthetic", folder: folder) else {
            throw TestFailure("the synthetic class's animation.json should read")
        }
        let size = CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        let window = HeadlessWindow(size: size)
        let avatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        avatar.sprites = sprites
        window.contentView = avatar
        window.show()
        Motion.reducesMotion = { false }
        avatar.configure(pose: .callingOut, beat: 0, finish: nil, reduceMotion: false)
        guard let character = shownCharacter(of: avatar) else {
            throw TestFailure("calling out should draw its character")
        }
        try expect(character.animation(forKey: TrackerAvatarMotionKey.frames) != nil, "calling out should loop before it finishes")
        let finishFrame = sprites.frame(.callingOut, .character, 3)
        let loopFrame = sprites.frame(.callingOut, .character, 1)
        avatar.configure(pose: .callingOut, beat: 0, finish: 0, reduceMotion: false)
        try expect(sameImage(character.contents, finishFrame), "a finish should show its own frame in place of the loop")
        try expect(character.animation(forKey: TrackerAvatarMotionKey.frames) == nil, "the loop should not run under the finish")
        avatar.configure(pose: .callingOut, beat: 0, finish: 0.1, reduceMotion: false)
        try expect(sameImage(character.contents, finishFrame), "a finish should hold its frame until the director moves it on")
        avatar.configure(pose: .callingOut, beat: 0, finish: nil, reduceMotion: false)
        let loop = character.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation
        try expect(sameImage(loop?.values?.first, loopFrame), "once the finish is over, the loop should start from its first frame")
        avatar.configure(pose: .callingOut, beat: 0, finish: 0, reduceMotion: true)
        try expect(sameImage(character.contents, loopFrame), "under Reduce Motion the finish should be skipped")
    }

    /// A synthetic class whose idle is a frame loop: three frames on the character and two on a front effect, with no `idle` legs and
    /// eyes and no fidgets in its file. Its idle art is a full-size canvas, since the tag measures the figure from f1.
    @MainActor
    private static func syntheticLoopingIdleFolder() throws -> URL {
        let folder = try syntheticClassFolder()
        let file = folder.appendingPathComponent("animation.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              var poses = json["poses"] as? [String: Any], var idle = poses["01-idle"] as? [String: Any] else {
            throw TestFailure("the synthetic class's animation.json should read as a JSON object with an idle")
        }
        idle["loop"] = ["character": [[1, 0.1], [2, 0.1], [3, 0.2]], "front": [[1, 0.2], [2, 0.2]]]
        poses["01-idle"] = idle
        json["poses"] = poses
        json.removeValue(forKey: "idle")
        json.removeValue(forKey: "fidgets")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        for number in 1...3 {
            try writeSolidFrame(Double(number) / 10, width: 64, height: 170, to: folder.appendingPathComponent("01-idle-f\(number).png"))
        }
        for number in 1...2 {
            try writeSolidFrame(Double(number) / 10 + 0.5, width: 64, height: 170, to: folder.appendingPathComponent("01-idle-front-f\(number).png"))
        }
        return folder
    }

    /// An idle with a loop cycles its frames like any steady pose and does none of the layered idle's work: no breath, no eyelids and
    /// no blink. It restarts from its first frame whenever it comes on screen, so a finish that ends on idle f1 lands on the loop's
    /// start, and Reduce Motion holds f1.
    @MainActor
    private static func testALoopingIdleCyclesItsFramesWithNoBreathOrBlink() throws {
        let folder = try syntheticLoopingIdleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let sprites = TrackerAvatarSprites(classID: "synthetic", folder: folder) else {
            throw TestFailure("the synthetic class with a looping idle should read")
        }
        try expect(sprites.animation.idle == nil && sprites.animation.fidgets.isEmpty && sprites.availableFidgets.isEmpty,
                   "a looping idle has no legs, eyes or fidgets")
        try expect(sprites.idleFigureHeight != nil, "the tag should still follow idle f1, the loop's first frame")
        let size = CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        let window = HeadlessWindow(size: size)
        let avatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        avatar.sprites = sprites
        window.contentView = avatar
        window.show()
        Motion.reducesMotion = { false }
        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        guard let character = shownCharacter(of: avatar),
              let loop = character.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation else {
            throw TestFailure("a looping idle should cycle its character frames")
        }
        let first = sprites.idleFrame(1)
        try expect(loop.values?.count == 4 && loop.calculationMode == .discrete && loop.repeatCount == .infinity && loop.duration == 0.4,
                   "idle should loop its three frames as discrete keyframes over 0.4 s, closing on f1")
        try expect(sameImage(loop.values?.first, first) && sameImage(loop.values?.last, first), "the loop should start and close on idle f1")
        let figure = character.superlayer
        try expect(figure?.sublayers?.dropFirst().first?.animation(forKey: TrackerAvatarMotionKey.frames) != nil, "the front effect should cycle on its own track")

        func hasLids(_ layer: CALayer) -> Bool {
            layer.name == TrackerAvatarMotionKey.lids || (layer.sublayers ?? []).contains(where: hasLids)
        }
        try expect(!(avatar.layer.map(hasLids) ?? true), "an authored idle loop should have no layered-idle blink overlay")

        // Out to another pose and back: the loop stops while idle is off screen, and starts again from its first frame.
        avatar.configure(pose: .callingOut, beat: 0, finish: nil, reduceMotion: false)
        try expect(character.animation(forKey: TrackerAvatarMotionKey.frames) == nil, "the loop should stop when idle goes off screen")
        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        let restarted = character.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation
        try expect(sameImage(restarted?.values?.first, first), "idle should start its loop from f1 when it comes back")

        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: true)
        try expect(character.animation(forKey: TrackerAvatarMotionKey.frames) == nil && sameImage(character.contents, first),
                   "under Reduce Motion idle should hold f1")
    }

    /// A temporary still idle for checking legacy eye shorthand and the no-eyes rest state.
    @MainActor
    private static func syntheticLayeredIdleFolder(eyes: Bool) throws -> URL {
        let folder = try syntheticClassFolder()
        let file = folder.appendingPathComponent("animation.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              var idle = json["idle"] as? [String: Any] else {
            throw TestFailure("the synthetic class's animation.json should read as an object with idle data")
        }
        if !eyes {
            for key in ["eye_row", "eye_columns", "lid_colour", "breathing"] {
                idle.removeValue(forKey: key)
            }
            idle["blink"] = false
        }
        json["idle"] = idle
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        try writeSolidFrame(0.1, width: 64, height: 170, to: folder.appendingPathComponent("01-idle-f1.png"))
        return folder
    }

    /// The layered-idle class folder with an idle effect: a three-step front track (0.8 s) and a one-step behind track (0.5 s) on a
    /// 128 x 180 canvas, with the figure's canvas at (20, 10) on it.
    @MainActor
    private static func syntheticIdleEffectFolder() throws -> URL {
        let folder = try syntheticLayeredIdleFolder(eyes: true)
        let file = folder.appendingPathComponent("animation.json")
        guard var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              var idle = json["idle"] as? [String: Any] else {
            throw TestFailure("the synthetic class's animation.json should read as an object with idle data")
        }
        idle["front"] = [[1, 0.3], [2, 0.3], [3, 0.2]]
        idle["behind"] = [[1, 0.5]]
        idle["character_at"] = ["x": 20, "y": 10]
        json["idle"] = idle
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        for number in 1...3 {
            try writeSolidFrame(Double(number) / 10, width: 128, height: 180, to: folder.appendingPathComponent("01-idle-front-f\(number).png"))
        }
        try writeSolidFrame(0.5, width: 128, height: 180, to: folder.appendingPathComponent("01-idle-behind-f1.png"))
        return folder
    }

    /// A frame of the idle loop with no art is missing, like any pose's, and the idle draws nothing until it lands.
    @MainActor
    private static func testALoopingIdleFrameWithoutArtIsMissing() throws {
        let folder = try syntheticLoopingIdleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let complete = TrackerAvatarSprites(classID: "synthetic", folder: folder) else {
            throw TestFailure("the synthetic class with a looping idle should read")
        }
        try expect(missingFrames(of: complete).filter { $0.hasPrefix("01-idle") }.isEmpty, "the synthetic idle should have all its art")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("01-idle-front-f2.png"))
        guard let damaged = TrackerAvatarSprites(classID: "synthetic", folder: folder) else {
            throw TestFailure("the synthetic class should still read")
        }
        let missing = missingFrames(of: damaged).filter { $0.hasPrefix("01-idle") }
        try expect(missing == ["01-idle front f2"], "the check should name the idle frame without art, got \(missing)")
        let size = CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        let window = HeadlessWindow(size: size)
        let avatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        avatar.sprites = damaged
        window.contentView = avatar
        window.show()
        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        try expect(shownCharacter(of: avatar) == nil, "an idle loop missing a frame should draw nothing, like any pose")
    }

    /// With no idle stencil an avatar rests on its still image and schedules no blink. Legacy eyes still make a lid layer and timer.
    @MainActor
    private static func testAnIdleWithoutLidDataRestsOnItsStillFrame() throws {
        defer { Motion.reducesMotion = { false } }
        let size = CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        let noEyesFolder = try syntheticLayeredIdleFolder(eyes: false)
        defer { try? FileManager.default.removeItem(at: noEyesFolder) }
        guard let noEyes = TrackerAvatarSprites(classID: "synthetic", folder: noEyesFolder) else {
            throw TestFailure("a still idle without eye metadata should read")
        }
        try expect(noEyes.animation.idle?.blink == false && noEyes.animation.idle?.stillLidPixels.isEmpty == true,
                   "an idle without stencil data should not blink")
        let noEyesWindow = HeadlessWindow(size: size)
        let noEyesAvatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        noEyesAvatar.sprites = noEyes
        noEyesWindow.contentView = noEyesAvatar
        noEyesWindow.show()
        noEyesAvatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        let stillRoot = (noEyesAvatar.layer?.sublayers ?? []).first(where: { !$0.isHidden })
        try expect(stillRoot?.sublayers?.count == 1 && stillRoot?.sublayers?.first?.animation(forKey: TrackerAvatarMotionKey.frames) == nil,
                   "an idle without breathing art should rest on its single still image")
        try expect(!noEyesAvatar.isBlinkScheduled, "an idle without lid data should schedule no blink")
        noEyesAvatar.showEyelids(true)
        try expect(stillRoot?.sublayers?.count == 1, "a forced blink should draw nothing without a lid stencil")

        let eyesFolder = try syntheticLayeredIdleFolder(eyes: true)
        defer { try? FileManager.default.removeItem(at: eyesFolder) }
        guard let eyes = TrackerAvatarSprites(classID: "synthetic", folder: eyesFolder) else {
            throw TestFailure("a still idle with legacy eye metadata should read")
        }
        let eyesWindow = HeadlessWindow(size: size)
        let eyesAvatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        eyesAvatar.sprites = eyes
        eyesWindow.contentView = eyesAvatar
        eyesWindow.show()
        Motion.reducesMotion = { false }
        eyesAvatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        let lids = (eyesAvatar.layer?.sublayers ?? []).first(where: { !$0.isHidden })?.sublayers?.first(where: { $0.name == TrackerAvatarMotionKey.lids })
        try expect(lids != nil && lids?.opacity == 0, "an idle with legacy eye metadata should carry a hidden lid image")
        try expect(eyesAvatar.isBlinkScheduled, "an idle with blink-enabled legacy eyes should schedule a blink")
        eyesAvatar.showEyelids(true)
        try expect(lids?.opacity == 1, "showing lids should paint the still stencil")
        eyesAvatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: true)
        try expect(!eyesAvatar.isBlinkScheduled, "Reduce Motion should stop the blink")

        guard let druid = TrackerAvatarSprites.bundled()["druid"] else {
            throw TestFailure("the druid's sprites should load")
        }
        let druidWindow = HeadlessWindow(size: size)
        let druidAvatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        druidAvatar.sprites = druid
        druidWindow.contentView = druidAvatar
        druidWindow.show()
        druidAvatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        try expect(!druidAvatar.isBlinkScheduled, "the druid's blink:false setting should prevent scheduled blinks")
        druidAvatar.showEyelids(true)
        let druidLids = (druidAvatar.layer?.sublayers ?? []).first(where: { !$0.isHidden })?.sublayers?.first(where: { $0.name == TrackerAvatarMotionKey.lids })
        try expect(druidLids?.opacity == 1, "a forced render should still be able to show the druid's recorded lid stencil")
    }

    /// A release whose file names its strike frame steps forward as that frame begins, not on its second step: the synthetic class's
    /// release enters on frames 1 and 2, strikes on frame 3 (0.2 s in) and follows through on frame 4, so the move's keys fall at 0.2 s
    /// and 0.4 s of its 0.5 s, and it ends back on its anchor.
    @MainActor
    private static func testAReleaseMovesOnItsNamedStrikeFrame() throws {
        let folder = try syntheticClassFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let sprites = TrackerAvatarSprites(classID: "synthetic", folder: folder),
              let placement = sprites.animation.animation(for: .release),
              let release = TrackerAvatarFrameRig(pose: .release, placement: placement, sprites: sprites) else {
            throw TestFailure("the synthetic class's release should draw")
        }
        try expect(placement.strikeFrame == 3, "the synthetic release should name frame 3 as its strike")
        release.place(in: CGRect(x: 0, y: 0, width: 260, height: 160))
        release.startMotion()
        guard let move = release.figure.animation(forKey: TrackerAvatarMotionKey.move) as? CAKeyframeAnimation else {
            throw TestFailure("a release should move the figure")
        }
        let pixel = Double(TrackerAvatarDesign.pixelPoints)
        let keyTimes = move.keyTimes?.map(\.doubleValue) ?? []
        let offsets = move.values?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        try expect(keyTimes.count == 4 && zip(keyTimes, [0, 0.4, 0.8, 1]).allSatisfy { abs($0 - $1) < 1e-9 },
                   "the move should step at the strike frame's start (0.4 of the one-shot) and at the next frame's (0.8), got \(keyTimes)")
        try expect(offsets == [0, 3 * pixel, 0, 0], "the move should step 3 pixels forward on the strike and end on the anchor, got \(offsets)")
    }

    /// The flight overlay sits above the terminal and the dock, takes no clicks or keys, and flies a spell from the avatar's hand to the
    /// Worker Log's left edge, level with the hand. Under Reduce Motion nothing flies.
    @MainActor
    private static func testTheFlightOverlaySitsAboveTheTerminalIgnoresHitsAndFliesToThePanelsEdge() throws {
        let sprites = try stillIdleSprites()
        let size = CGSize(width: 800, height: 500)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let terminal = NSView(frame: root.bounds)
        terminal.autoresizingMask = [.width, .height]
        root.addSubview(terminal)
        let avatarView = TrackerAvatarView(frame: NSRect(x: 40, y: 40, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight))
        root.addSubview(avatarView)
        let handle = TrackerAvatarHandle()
        handle.view = avatarView
        let panel = NSRect(x: 560, y: 0, width: 240, height: size.height)
        let overlay = TrackerFlightOverlay(avatar: handle, sprites: { sprites }, workerLogFrame: { panel })
        overlay.frame = root.bounds
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay)
        let window = HeadlessWindow(size: size)
        window.contentView = root
        window.show()
        Motion.reducesMotion = { false }

        try expect(root.subviews.last === overlay, "the flight overlay should sit above the terminal, the dock and the tracker")
        try expect(!overlay.acceptsFirstResponder, "the flight overlay should never take the keys")
        try expect(overlay.hitTest(NSPoint(x: 700, y: 300)) == nil, "the flight overlay should take no clicks")
        try expect(root.hitTest(NSPoint(x: 700, y: 300)) === terminal, "a click over the terminal should still reach the terminal")

        overlay.fly(TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker("qm-2")))
        let flights = (overlay.layer?.sublayers ?? []).compactMap { $0.animation(forKey: "spell-flight") as? CAKeyframeAnimation }
        guard let flight = flights.first, let start = flight.values?.first as? NSValue, let end = flight.values?.last as? NSValue else {
            throw TestFailure("a spell should fly from the avatar's hand to the Worker Log's edge")
        }
        // The hand in the layer's own bottom-left coordinates, from the sprites' hand point in the slot's top-left ones.
        let slot = CGRect(x: 40, y: size.height - 40 - TrackerAvatarMetrics.slotHeight, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        guard let hand = sprites.handPoint(in: slot) else {
            throw TestFailure("the wizard should have a hand point")
        }
        let handLayer = CGPoint(x: hand.x, y: size.height - hand.y)
        try expect(abs(start.pointValue.x - handLayer.x) < 0.5 && abs(start.pointValue.y - handLayer.y) < 0.5,
                   "a flight should start at the avatar's hand, got \(start.pointValue)")
        let landing = end.pointValue
        try expect(abs(landing.x - panel.minX) < 0.5 && abs(landing.y - handLayer.y) < 0.5,
                   "a flight should land on the Worker Log's left edge at the hand's height, got \(landing)")

        let spellCount = overlay.layer?.sublayers?.count ?? 0
        Motion.reducesMotion = { true }
        overlay.fly(TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker("qm-2")))
        try expect((overlay.layer?.sublayers?.count ?? 0) == spellCount, "under Reduce Motion nothing should fly")
        Motion.reducesMotion = { false }
    }

    /// The synthetic class's spells: the wisp has a 3-frame flight with its head anchored at the right and a 2-frame impact, the
    /// messenger has a 2-frame flight with no anchor and a still impact, and the orb keeps both stills.
    @MainActor
    private static func syntheticSpellSprites(in folder: URL) throws -> TrackerAvatarSprites {
        guard let sprites = TrackerAvatarSprites(classID: "synthetic", folder: folder) else {
            throw TestFailure("the synthetic class's animation.json should read")
        }
        return sprites
    }

    /// A flight overlay over a window, with the avatar's view at its left and a Worker Log panel at its right edge for the spells to
    /// land on. The window stays up as long as the stage does.
    private struct FlightStage {
        let size: CGSize
        let root: NSView
        let handle: TrackerAvatarHandle
        let panel: NSRect
        let overlay: TrackerFlightOverlay
        let window: HeadlessWindow
    }

    @MainActor
    private static func flightStage(for sprites: TrackerAvatarSprites) -> FlightStage {
        let size = CGSize(width: 800, height: 500)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let avatarView = TrackerAvatarView(frame: NSRect(x: 40, y: 40, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight))
        root.addSubview(avatarView)
        let handle = TrackerAvatarHandle()
        handle.view = avatarView
        let panel = NSRect(x: 560, y: 0, width: 240, height: size.height)
        let overlay = TrackerFlightOverlay(avatar: handle, sprites: { sprites }, workerLogFrame: { panel })
        overlay.frame = root.bounds
        overlay.autoresizingMask = [.width, .height]
        root.addSubview(overlay)
        let window = HeadlessWindow(size: size)
        window.contentView = root
        window.show()
        return FlightStage(size: size, root: root, handle: handle, panel: panel, overlay: overlay, window: window)
    }

    /// The layer `overlay` adds when `flight` flies.
    @MainActor
    private static func flownSpell(_ flight: TrackerSpellFlight, by overlay: TrackerFlightOverlay) throws -> CALayer {
        let before = overlay.layer?.sublayers?.count ?? 0
        overlay.fly(flight)
        guard let layers = overlay.layer?.sublayers, layers.count == before + 1, let spell = layers.last else {
            throw TestFailure("\(flight.spell) should fly")
        }
        return spell
    }

    /// A spell with frames cycles its flight while it flies, drawn facing right with its anchor on the path: it is mirrored about that
    /// anchor on a flight that heads left (the returning wisp), so the head leads on every path, and not on one that heads right. The
    /// frames run for the flight and no longer. The impact plays its frames once where the flight lands, and goes. A spell with
    /// stills is drawn as it was: centred, never mirrored, with no frames. Under Reduce Motion nothing flies.
    @MainActor
    private static func testASpellWithFramesFliesHeadFirstAndPlaysItsImpactOnce() throws {
        let folder = try syntheticClassFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sprites = try syntheticSpellSprites(in: folder)
        guard let wispFlight = sprites.flight(for: .wisp), let wispImpact = sprites.impact(for: .wisp),
              let messengerFlight = sprites.flight(for: .messenger), let orbFlight = sprites.flight(for: .orb) else {
            throw TestFailure("the synthetic spells should have their art")
        }
        try expect(wispFlight.frames.count == 3 && wispFlight.track?.seconds == 0.4 && wispFlight.anchor == CGPoint(x: 7.5, y: 2.5),
                   "the wisp should fly three frames on its anchor's pixel, got \(wispFlight.frames.count) frames at \(wispFlight.anchor)")
        try expect(wispImpact.frames.count == 2 && wispImpact.anchor == CGPoint(x: 3, y: 3), "the wisp's impact should play two frames, centred")
        try expect(messengerFlight.frames.count == 2 && messengerFlight.anchor == CGPoint(x: 3, y: 2), "an unanchored flight should be anchored at its centre")
        try expect(wispFlight.drawnFacing == .right && messengerFlight.drawnFacing == .right, "frames should face right unless the file says")
        try expect(orbFlight.track == nil && orbFlight.drawnFacing == nil && orbFlight.anchor == CGPoint(x: 2, y: 2),
                   "a still that doesn't say should have no frames and no facing")

        let stage = flightStage(for: sprites)
        let (overlay, root, handle, panel) = (stage.overlay, stage.root, stage.handle, stage.panel)
        let pixel = TrackerAvatarDesign.pixelPoints
        Motion.reducesMotion = { false }
        let wisp = try flownSpell(TrackerSpellFlight(spell: .wisp, from: .worker("qm-2"), to: .avatar), by: overlay)
        guard let move = wisp.animation(forKey: "spell-flight") as? CAKeyframeAnimation,
              let cycle = wisp.animation(forKey: "spell-frames") as? CAKeyframeAnimation else {
            throw TestFailure("the wisp should move along its path and cycle its frames")
        }
        try expect(wisp.transform.m11 == -1, "the wisp heads left, so it should be mirrored, got m11 \(wisp.transform.m11)")
        try expect(abs(wisp.anchorPoint.x - 7.5 / 8) < 1e-9 && abs(wisp.anchorPoint.y - (1 - 2.5 / 4)) < 1e-9,
                   "the wisp's anchor should ride the path: the middle of its head pixel (column 7, row 2), got \(wisp.anchorPoint)")
        // Mirrored about its anchor: the head pixel stays on the path point and the trail, drawn to the left, streams out to the right.
        try expect(abs(wisp.frame.minX - (wisp.position.x - 0.5 * pixel)) < 1e-9 && abs(wisp.frame.maxX - (wisp.position.x + 7.5 * pixel)) < 1e-9,
                   "a wisp heading left should trail to the right of its head, got \(wisp.frame) at \(wisp.position)")
        try expect(cycle.calculationMode == .discrete && cycle.values?.count == 4 && cycle.duration == 0.4,
                   "the wisp should cycle its three frames with a closing key, as discrete keyframes over its track")
        try expect(cycle.repeatCount == 0 && abs(cycle.repeatDuration - move.duration) < 1e-9,
                   "the frames should repeat for the flight and no longer, not forever: \(cycle.repeatCount), \(cycle.repeatDuration)")
        let messenger = try flownSpell(TrackerSpellFlight(spell: .messenger, from: .avatar, to: .worker("qm-2")), by: overlay)
        try expect(messenger.transform.m11 == 1 && messenger.animation(forKey: "spell-frames") != nil,
                   "a flight that heads right should cycle its frames unmirrored")
        try expect(abs(messenger.frame.minX - (messenger.position.x - 3 * pixel)) < 1e-9,
                   "a flight that heads right should keep its trail to the left, got \(messenger.frame) at \(messenger.position)")
        try expect(abs(messenger.anchorPoint.x - 0.5) < 1e-9 && abs(messenger.anchorPoint.y - 0.5) < 1e-9, "an unanchored flight should ride on its centre")
        let orb = try flownSpell(TrackerSpellFlight(spell: .orb, from: .worker("qm-2"), to: .avatar), by: overlay)
        try expect(orb.transform.m11 == 1 && orb.animation(forKey: "spell-frames") == nil && orb.anchorPoint == CGPoint(x: 0.5, y: 0.5),
                   "a still should be drawn as it was even on a flight that heads left: no frames, no mirror, centred")

        let count = overlay.layer?.sublayers?.count ?? 0
        Motion.reducesMotion = { true }
        overlay.fly(TrackerSpellFlight(spell: .wisp, from: .worker("qm-2"), to: .avatar))
        Motion.reducesMotion = { false }
        try expect((overlay.layer?.sublayers?.count ?? 0) == count, "under Reduce Motion nothing should fly")

        // Land the wisp alone: its flight layer goes, its impact plays its two frames once, and then nothing is left.
        let lone = TrackerFlightOverlay(avatar: handle, sprites: { sprites }, workerLogFrame: { panel })
        lone.frame = root.bounds
        root.addSubview(lone)
        lone.fly(TrackerSpellFlight(spell: .wisp, from: .worker("qm-2"), to: .avatar))
        RunLoop.current.run(until: Date().addingTimeInterval(Motion.duration(.flight) + 0.15))
        guard let impact = lone.layer?.sublayers?.first, lone.layer?.sublayers?.count == 1,
              let burst = impact.animation(forKey: "spell-impact") as? CAKeyframeAnimation else {
            throw TestFailure("a wisp that has landed should leave only its impact, playing, got \(lone.layer?.sublayers?.count ?? -1) layers")
        }
        try expect(burst.values?.count == 3 && burst.calculationMode == .discrete && burst.repeatCount == 0 && burst.repeatDuration == 0 && burst.duration == 0.2,
                   "the impact should play its two frames once, over its track's 0.2 s, with the last key holding the final frame")
        try expect(impact.transform.m11 == 1, "the impact is a burst, not mirrored")
        RunLoop.current.run(until: Date().addingTimeInterval(0.2 + 0.3))
        try expect((lone.layer?.sublayers ?? []).isEmpty, "the impact should go when its frames have played, so nothing keeps running after a spell lands")
    }

    /// A still whose file says which way it faces is mirrored on a flight that heads the other way, so its head leads, and isn't on one
    /// that heads the same way. It rides its centre and trails behind it. A still that doesn't say is never mirrored.
    @MainActor
    private static func testAStillThatSaysWhichWayItFacesLeadsWithItsHead() throws {
        let folder = try syntheticClassFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("animation.json")
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
              var spells = object["spells"] as? [String: Any] else {
            throw TestFailure("the synthetic class's animation.json should read as a JSON object with spells")
        }
        spells["S1-summoning-orb"] = ["faces": "left"]
        object["spells"] = spells
        let animation = try TrackerAvatarAnimation(data: JSONSerialization.data(withJSONObject: object))
        let sprites = TrackerAvatarSprites(classID: "synthetic", animation: animation, folder: folder)
        guard let orb = sprites.flight(for: .orb) else {
            throw TestFailure("the synthetic orb should have its still")
        }
        try expect(orb.track == nil && orb.drawnFacing == .left && orb.anchor == CGPoint(x: 2, y: 2), "the orb should be a still that faces left, centred")
        try expect(orb.trailPixels == 2, "a still facing left trails on its right side, got \(orb.trailPixels)")
        let stage = flightStage(for: sprites)
        Motion.reducesMotion = { false }
        let heading = try flownSpell(TrackerSpellFlight(spell: .orb, from: .avatar, to: .worker("qm-2")), by: stage.overlay)
        try expect(heading.transform.m11 == -1, "an orb facing left that heads right should be mirrored, got m11 \(heading.transform.m11)")
        let returning = try flownSpell(TrackerSpellFlight(spell: .orb, from: .worker("qm-2"), to: .avatar), by: stage.overlay)
        try expect(returning.transform.m11 == 1, "an orb facing left that heads left should be drawn as it is, got m11 \(returning.transform.m11)")
    }

    /// Every bundled class's still flights lead with their heads on their paths. Only the returning wisp flies left; the orb and the
    /// messenger fly right. How each still is drawn is read from the art: the druid's, the necromancer's, the sorcerer's and the fighter's wisps face left already, and every
    /// other still faces right, so a wisp that faces right needs its file to say so (`faces`) to be mirrored on its way back.
    @MainActor
    private static func testEveryBundledStillLeadsWithItsHeadOnItsPath() throws {
        let drawnLeft: Set<String> = ["druid S6-returning-wisp", "necromancer S6-returning-wisp", "sorcerer S6-returning-wisp", "fighter S6-returning-wisp"]
        for (classID, sprites) in TrackerAvatarSprites.bundled().sorted(by: { $0.key < $1.key }) {
            for spell in TrackerSpellFlight.Spell.allCases {
                guard let art = sprites.flight(for: spell) else {
                    throw TestFailure("the \(classID)'s \(spell.resourceName) should have its flight art")
                }
                let drawn: TrackerAvatarFacing = drawnLeft.contains("\(classID) \(spell.resourceName)") ? .left : .right
                let path: TrackerAvatarFacing = spell == .wisp ? .left : .right
                let mirrored = art.isMirrored(headsLeft: path == .left)
                let shown: TrackerAvatarFacing = mirrored ? (drawn == .left ? .right : .left) : drawn
                try expect(shown == path, "the \(classID)'s \(spell.resourceName) is drawn facing \(drawn) and flies \(path), so it should lead with its head, but it shows facing \(shown)")
            }
        }
    }

    /// A frame a spell's file plays that has no art is missing, as a pose's is: the spell can't be drawn, and the check names it.
    @MainActor
    private static func testASpellFrameWithoutArtIsMissing() throws {
        let folder = try syntheticClassFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let complete = try syntheticSpellSprites(in: folder)
        try expect(complete.animation.spell(.wisp)?.flight?.steps.count == 3, "the synthetic wisp should fly three frames")
        let spellMissing = missingFrames(of: complete).filter { $0.hasPrefix("S") }
        try expect(spellMissing.isEmpty, "the synthetic spells should have all their art, missing: \(spellMissing)")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("S6-returning-wisp-flight-f2.png"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("S1-summoning-orb-impact.png"))
        let damaged = try syntheticSpellSprites(in: folder)
        try expect(damaged.flight(for: .wisp) == nil, "a wisp missing a flight frame should have no flight art")
        try expect(damaged.impact(for: .orb) == nil, "an orb missing its impact still should have no impact art")
        let missing = missingFrames(of: damaged).filter { $0.hasPrefix("S") }
        try expect(missing == ["S1-summoning-orb impact still", "S6-returning-wisp flight f2"],
                   "the check should name each spell frame without art, got \(missing)")
    }

    /// The stage reads each payload's spawn, message and report, and launches the spell each one flies, in order. Its clock is the
    /// test's own, so the spawn's summoning has time to show before the orb leaves.
    @MainActor
    private static func testTheStageLaunchesEachSpellFromItsPayloads() throws {
        final class Clock {
            var now: TimeInterval = 0
        }
        let clock = Clock()
        let stage = TrackerAvatarStage(clock: { clock.now })
        func row(_ fields: [String: Any]) throws -> TrackerSession {
            var payload: [String: Any] = ["status": "active", "state": "working", "agent": "claude", "elapsed_ms": 0, "worker_count": 0]
            payload.merge(fields) { _, new in new }
            return try JSONDecoder().decode(TrackerSession.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let master = try row(["id": "qm-m", "title": "Wizard", "session_type": "master", "class": "wizard"])
        let worker = try row(["id": "qm-w", "title": "Ember", "session_type": "worker", "parent_id": "qm-m"])
        let messaged = try row(["id": "qm-w", "title": "Ember", "session_type": "worker", "parent_id": "qm-m",
                                "last_exchange": ["kind": "instructions", "at": "2026-10-30T13:26:05.000001Z"]])
        let reported = try row(["id": "qm-w", "title": "Ember", "session_type": "worker", "parent_id": "qm-m",
                                "last_exchange": ["kind": "report", "at": "2026-10-30T13:26:09.000001Z"]])
        guard let wizardSummoning = TrackerAvatarSprites.bundled()["wizard"]?.animation.animation(for: .summoning) else {
            throw TestFailure("the wizard's sprites should load from the app bundle")
        }
        let summoning = (wizardSummoning.enter?.seconds ?? 0) + (wizardSummoning.loop?.seconds ?? 0) + (wizardSummoning.finish?.seconds ?? 0)

        var launched: [TrackerSpellFlight] = []
        stage.onLaunch = { launched.append($0) }
        stage.observe(sessions: [master], attachedID: "qm-m")
        clock.now = 1
        stage.observe(sessions: [master, worker], attachedID: "qm-m")
        clock.now = 1 + summoning + 0.01
        stage.observe(sessions: [master, worker], attachedID: "qm-m")
        clock.now = 5
        stage.observe(sessions: [master, messaged], attachedID: "qm-m")
        clock.now = 9
        stage.observe(sessions: [master, reported], attachedID: "qm-m")
        clock.now = 10
        stage.observe(sessions: [master, reported], attachedID: "qm-m")
        let spells = launched.map(\.spell)
        try expect(spells == [.orb, .messenger, .wisp], "each payload should launch its spell once, got \(spells)")
    }

    /// The character layer of the avatar's shown frame rig: the figure's first layer, under the rig's root.
    @MainActor
    private static func shownCharacter(of avatar: TrackerAvatarView) -> CALayer? {
        let root = (avatar.layer?.sublayers ?? []).first { !$0.isHidden }
        // The root holds the behind effect, then the figure, then the bubble.
        return root?.sublayers?.dropFirst().first?.sublayers?.first
    }

    /// Whether a layer's contents, or a keyframe's value, is `image` itself.
    private static func sameImage(_ value: Any?, _ image: CGImage?) -> Bool {
        guard let value, let image else {
            return false
        }
        return (value as AnyObject) === image
    }

    /// The bard's sprites load from the app bundle: their animation file reads, and the art the avatar draws from it is there. His
    /// idle is a strumming loop, so it has no idle layers and no fidgets.
    @MainActor
    private static func testBundledBardSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["bard"] else {
            throw TestFailure("the bard's sprites should load from the app bundle")
        }
        try expect(sprites.animation.animation(for: .idle)?.loop != nil, "the bard's idle should be a strumming loop")
        try expect(sprites.animation.idle == nil && sprites.animation.fidgets.isEmpty, "the bard's looping idle should have no idle layers or fidgets")
        try expect(sprites.handPoint(in: CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)) != nil,
                   "the bard's release should have a hand")
        try expect(TrackerAvatarPose.allCases.allSatisfy { sprites.canvasSize(for: $0) != nil }, "every pose should have the bard's art")
        try expect([.orb, .messenger, .wisp].allSatisfy { sprites.flight(for: $0) != nil && sprites.impact(for: $0) != nil },
                   "the bard should have the art of all three spells")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the bard's file plays should have its art, missing: \(missing)")
    }

    @MainActor
    private static func testBundledWizardSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["wizard"] else {
            throw TestFailure("the wizard's sprites should load from the app bundle")
        }
        try expect(sprites.animation.idle?.breathing?.frames.count == 6, "the wizard should load its six sparse breathing images")
        try expect(sprites.animation.fidgets.map(\.name) == ["hood", "staff-tap"], "the wizard should have the hood and staff-tap fidgets")
        try expect(sprites.availableFidgets.count == 2, "both of the wizard's fidgets should have their art")
        try expect(sprites.idleBreathingArt?.count == 6, "the wizard's breathing track should load every image and lid stencil")
        try expect(sprites.idleStillArt != nil, "the wizard should have a still idle image")
        try expect(TrackerAvatarPose.allCases.allSatisfy { sprites.canvasSize(for: $0) != nil }, "every pose should have the wizard's art")
        try expect([.orb, .messenger, .wisp].allSatisfy { sprites.flight(for: $0) != nil && sprites.impact(for: $0) != nil },
                   "the wizard should have the art of all three spells")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the wizard's file plays should have its art, missing: \(missing)")
    }

    @MainActor
    private static func testBundledPaladinSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["paladin"] else {
            throw TestFailure("the paladin's sprites should load from the app bundle")
        }
        try expect(sprites.animation.idle?.blink == false, "the paladin wears a closed helm, so he should not schedule a blink")
        try expect(sprites.animation.idle?.breathing?.frames.count == 8 && sprites.idleBreathingArt?.count == 8,
                   "the paladin should load all eight breathing images")
        try expect(sprites.animation.fidgets.map(\.name) == ["shrug"], "the paladin should have the shrug fidget")
        try expect(sprites.availableFidgets.count == 1, "the paladin's fidget should have its art")
        try expect(sprites.idleStillArt != nil, "the paladin should have a still idle image")
        try expect(TrackerAvatarPose.allCases.allSatisfy { sprites.canvasSize(for: $0) != nil }, "every pose should have the paladin's art")
        try expect([.orb, .messenger, .wisp].allSatisfy { sprites.flight(for: $0) != nil && sprites.impact(for: $0) != nil },
                   "the paladin should have the art of all three spells")
        try expect(sprites.handPoint(in: CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)) != nil,
                   "the paladin's release should have a hand")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the paladin's file plays should have its art, missing: \(missing)")
    }

    @MainActor
    private static func testBundledDruidSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["druid"] else {
            throw TestFailure("the druid's sprites should load from the app bundle")
        }
        try expect(sprites.animation.idle?.blink == false, "the druid should not schedule a blink")
        try expect(sprites.animation.idle?.breathing?.frames.count == 8 && sprites.idleBreathingArt?.count == 8,
                   "the druid should load all eight authored frames and eyelid stencils")
        try expect(sprites.availableFidgets.count > 0, "the druid's bird fidget art should remain available")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the druid's file plays should have its art, missing: \(missing)")
    }

    @MainActor
    private static func testBundledRogueSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["rogue"] else {
            throw TestFailure("the rogue's sprites should load from the app bundle")
        }
        guard let breathing = sprites.animation.idle?.breathing else {
            throw TestFailure("the rogue's authored breathing track should load")
        }
        try expect(breathing.frames.count == 8 && sprites.idleBreathingArt?.count == 8,
                   "the rogue should load all eight sparse breathing frames and their lid stencils")
        try expect(breathing.frames.allSatisfy { Set($0.lidPixels.map(\.y)).count > 1 },
                   "the rogue's blink stencils should preserve their multi-row pixels")
        try expect([.orb, .messenger, .wisp].allSatisfy { sprites.flight(for: $0)?.drawnFacing == .right },
                   "the rogue's three authored spells should face right before their paths mirror them")
        try expect(TrackerAvatarPose.allCases.allSatisfy { sprites.canvasSize(for: $0) != nil },
                   "every pose should have the rogue's art")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the rogue's file plays should have its art, missing: \(missing)")
    }

    @MainActor
    private static func testBundledClericSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["cleric"] else {
            throw TestFailure("the cleric's sprites should load from the app bundle")
        }
        try expect(sprites.animation.idle?.breathing?.frames.count == 14 && sprites.idleBreathingArt?.count == 14,
                   "the cleric should load all fourteen breathing steps and their lid stencils")
        try expect(sprites.animation.fidgets.map(\.name) == ["mitre"], "the cleric should have the mitre fidget")
        try expect(sprites.availableFidgets.count == 1, "the cleric's fidget should have its art")
        try expect(sprites.idleStillArt != nil, "the cleric should have a still idle image")
        try expect(TrackerAvatarPose.allCases.allSatisfy { sprites.canvasSize(for: $0) != nil }, "every pose should have the cleric's art")
        try expect([.orb, .messenger, .wisp].allSatisfy { sprites.flight(for: $0) != nil && sprites.impact(for: $0) != nil },
                   "the cleric should have the art of all three spells")
        try expect(sprites.handPoint(in: CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)) != nil,
                   "the cleric's release should have a hand")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the cleric's file plays should have its art, missing: \(missing)")
    }

    /// The ranger's sprites load from the app bundle: his breathing plays its authored steps up and back down with their eyelid
    /// stencils, he never blinks, and all three spells have their frame art.
    @MainActor
    private static func testBundledRangerSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["ranger"] else {
            throw TestFailure("the ranger's sprites should load from the app bundle")
        }
        try expect(sprites.animation.idle?.blink == false, "the ranger should not schedule a blink")
        try expect(sprites.animation.idle?.breathing?.frames.count == 16 && sprites.idleBreathingArt?.count == 16,
                   "the ranger should load all sixteen breathing steps and their lid stencils")
        try expect(sprites.animation.fidgets.map(\.name) == ["scarf-tug"], "the ranger should have the scarf-tug fidget")
        try expect(sprites.availableFidgets.count == 1, "the ranger's fidget should have its art")
        try expect(TrackerAvatarPose.allCases.allSatisfy { sprites.canvasSize(for: $0) != nil }, "every pose should have the ranger's art")
        try expect([.orb, .messenger, .wisp].allSatisfy { sprites.flight(for: $0) != nil && sprites.impact(for: $0) != nil },
                   "the ranger should have the frame art of all three spells")
        try expect(sprites.handPoint(in: CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)) != nil,
                   "the ranger's release should have a hand")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the ranger's file plays should have its art, missing: \(missing)")
    }

    /// The bard's three spells are frame tracks drawn facing right: each has flight and impact art, no still is left, and the wisp is
    /// mirrored on its way back because its file says which way it faces.
    @MainActor
    private static func testBundledBardSpellsPlayFramesFacingRight() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["bard"] else {
            throw TestFailure("the bard's sprites should load from the app bundle")
        }
        for spell in TrackerSpellFlight.Spell.allCases {
            let track = sprites.animation.spell(spell)
            try expect(track?.flight != nil && track?.impact != nil,
                       "the bard's \(spell.resourceName) should play flight and impact frames")
            try expect(track?.faces == .right, "the bard's \(spell.resourceName) should say it is drawn facing right")
            try expect(sprites.flight(for: spell) != nil && sprites.impact(for: spell) != nil,
                       "the bard's \(spell.resourceName) should have its flight and impact art")
            let folder = AppSymbolStyle.resourceBundle().resourceURL?.appendingPathComponent("Sprites/bard", isDirectory: true)
            let stills = ["flight", "impact"].map { folder?.appendingPathComponent("\(spell.resourceName)-\($0).png").path ?? "" }
            try expect(stills.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "the bard's \(spell.resourceName) should have no still left")
        }
        guard let wisp = sprites.flight(for: .wisp) else {
            throw TestFailure("the bard's wisp should have its flight art")
        }
        try expect(wisp.isMirrored(headsLeft: true) && !wisp.isMirrored(headsLeft: false), "the bard's wisp should be mirrored only on its way back")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the bard's file plays should have its art, missing: \(missing)")
    }

    /// The druid's bubble sits at her left, so it says its tail points right, and the rig draws it flipped at the same box.
    @MainActor
    private static func testBundledDruidBubbleTailPointsAtHer() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["druid"],
              let pose = sprites.animation.animation(for: .callingOut) else {
            throw TestFailure("the druid's calling out should load from the app bundle")
        }
        try expect(pose.bubble == TrackerAvatarPixel(x: 40, y: 9), "the druid's bubble should sit at x 40, y 9, got \(String(describing: pose.bubble))")
        try expect(pose.bubbleTail == .right, "the druid's bubble tail should point right, at her")
        guard let rig = TrackerAvatarFrameRig(pose: .callingOut, placement: pose, sprites: sprites) else {
            throw TestFailure("the druid's calling out should draw")
        }
        rig.place(in: CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight))
        try expect(CATransform3DEqualToTransform(rig.bubble.transform, CATransform3DMakeScale(-1, 1, 1)), "the druid's bubble should draw flipped")
    }

    /// The sorcerer's sprites load from the app bundle: her breathing plays its eight authored steps, each with a lid stencil, she blinks
    /// in her own lid colour, her bubble's tail points at her, and her spells have frame art.
    @MainActor
    private static func testBundledSorcererSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["sorcerer"] else {
            throw TestFailure("the sorcerer's sprites should load from the app bundle")
        }
        try expect(sprites.animation.idle?.blink == true, "the sorcerer should schedule a blink")
        try expect(sprites.animation.idle?.lidColour == TrackerAvatarColour(rgb: 0xebae9e), "the sorcerer should blink in her skin colour")
        try expect(sprites.animation.idle?.breathing?.frames.count == 8 && sprites.idleBreathingArt?.count == 8,
                   "the sorcerer should load all eight breathing steps and their lid stencils")
        try expect(sprites.idleBreathingArt?.allSatisfy { $0.lids != nil } == true, "every sorcerer breathing frame should carry a blink stencil")
        try expect(sprites.animation.fidgets.map(\.name) == ["hair-flick"] && sprites.availableFidgets.count == 1,
                   "the sorcerer should have the hair-flick fidget with its art")
        try expect(TrackerAvatarPose.allCases.allSatisfy { sprites.canvasSize(for: $0) != nil }, "every pose should have the sorcerer's art")
        try expect([.orb, .messenger, .wisp].allSatisfy { sprites.flight(for: $0) != nil && sprites.impact(for: $0) != nil },
                   "the sorcerer should have the frame art of all three spells")
        try expect(sprites.handPoint(in: CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)) != nil,
                   "the sorcerer's release should have a hand")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the sorcerer's file plays should have its art, missing: \(missing)")
    }

    /// The fighter's sprites load from the app bundle: his breathing plays its nine authored steps, each with a lid stencil, he blinks in his
    /// own lid colour, his bubble's tail points at him, and his three spells have frame art.
    @MainActor
    private static func testBundledFighterSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["fighter"] else {
            throw TestFailure("the fighter's sprites should load from the app bundle")
        }
        try expect(sprites.animation.idle?.blink == true, "the fighter should schedule a blink")
        try expect(sprites.animation.idle?.lidColour == TrackerAvatarColour(rgb: 0x7a4a3a), "the fighter should blink in his skin colour")
        try expect(sprites.animation.idle?.breathing?.frames.count == 9 && sprites.idleBreathingArt?.count == 9,
                   "the fighter should load all nine breathing steps and their lid stencils")
        try expect(sprites.idleBreathingArt?.allSatisfy { $0.lids != nil } == true, "every fighter breathing frame should carry a blink stencil")
        try expect(sprites.animation.fidgets.map(\.name) == ["sword-lowered-gaze"] && sprites.availableFidgets.count == 1,
                   "the fighter should have the sword-lowered gaze fidget with its art")
        try expect(TrackerAvatarPose.allCases.allSatisfy { sprites.canvasSize(for: $0) != nil }, "every pose should have the fighter's art")
        try expect([.orb, .messenger, .wisp].allSatisfy { sprites.flight(for: $0) != nil && sprites.impact(for: $0) != nil },
                   "the fighter should have the frame art of all three spells")
        try expect(sprites.handPoint(in: CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)) != nil,
                   "the fighter's release should have a hand")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the fighter's file plays should have its art, missing: \(missing)")
    }

    /// An idle's effect layer: a looping track on its own clock, over (`front`) or under (`behind`) the figure, placed by where the
    /// figure's canvas falls on its own. It keeps playing through a fidget, rests on its first frame under Reduce Motion, and goes
    /// with the idle. A class whose file has no such key draws no layer for it.
    @MainActor
    private static func testAnIdleEffectLayerPlaysOnItsOwnClockThroughFidgets() throws {
        defer { Motion.reducesMotion = { false } }
        Motion.reducesMotion = { false }
        let folder = try syntheticIdleEffectFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let sprites = TrackerAvatarSprites(classID: "synthetic", folder: folder) else {
            throw TestFailure("the synthetic class with an idle effect should read")
        }
        try expect(missingFrames(of: sprites).filter { $0.hasPrefix("idle effect") }.isEmpty, "the synthetic idle effect should have all its art")
        let size = CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        let window = HeadlessWindow(size: size)
        let avatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        avatar.sprites = sprites
        window.contentView = avatar
        window.show()
        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        let roots = avatar.layer?.sublayers ?? []
        guard let front = roots.first(where: { $0.zPosition > 0 && !$0.isHidden }),
              let behind = roots.first(where: { $0.zPosition < 0 && !$0.isHidden }),
              let figure = roots.first(where: { $0.zPosition == 0 && !$0.isHidden }) else {
            throw TestFailure("an idle with effects should show a front layer, a behind layer and the figure")
        }
        guard let frontPlay = front.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation,
              let behindPlay = behind.animation(forKey: TrackerAvatarMotionKey.frames) as? CAKeyframeAnimation else {
            throw TestFailure("the effect layers should play their frames")
        }
        try expect(abs(frontPlay.duration - 0.8) < 1e-9 && frontPlay.repeatCount == .infinity && frontPlay.values?.count == 4,
                   "the front effect should loop its 0.8 s track and close on its first frame")
        try expect(abs(behindPlay.duration - 0.5) < 1e-9, "the behind effect should keep its own 0.5 s clock")
        let pixel = TrackerAvatarDesign.pixelPoints
        try expect(front.frame.minX == figure.frame.minX - 20 * pixel && front.frame.maxY == figure.frame.maxY + 10 * pixel,
                   "the effect canvas should place the figure's canvas at character_at, got \(front.frame) against \(figure.frame)")
        // A fidget swaps the figure but not the effects.
        avatar.configure(pose: .idle, fidget: 2, beat: 0, finish: nil, reduceMotion: false)
        try expect(!front.isHidden && front.animation(forKey: TrackerAvatarMotionKey.frames) != nil, "the front effect should play through a fidget")
        // Reduce Motion rests each layer on its first frame.
        Motion.reducesMotion = { true }
        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: true)
        try expect(!front.isHidden && front.animation(forKey: TrackerAvatarMotionKey.frames) == nil
                   && sameImage(front.contents, sprites.frame(.idle, .front, 1)), "Reduce Motion should hold the front effect's first frame")
        Motion.reducesMotion = { false }
        avatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        avatar.configure(pose: .pondering, beat: 0, finish: nil, reduceMotion: false)
        try expect(front.isHidden && behind.isHidden, "another pose should hide the idle's effects")

        // A class whose file has no idle effect draws no layer for it.
        let plainFolder = try syntheticLayeredIdleFolder(eyes: true)
        defer { try? FileManager.default.removeItem(at: plainFolder) }
        guard let plain = TrackerAvatarSprites(classID: "synthetic", folder: plainFolder) else {
            throw TestFailure("the plain synthetic class should read")
        }
        try expect(plain.animation.idle?.front == nil && plain.animation.idle?.behind == nil, "a file without the keys should decode no effect")
        let plainWindow = HeadlessWindow(size: size)
        let plainAvatar = TrackerAvatarView(frame: NSRect(origin: .zero, size: size))
        plainAvatar.sprites = plain
        plainWindow.contentView = plainAvatar
        plainWindow.show()
        plainAvatar.configure(pose: .idle, beat: 0, finish: nil, reduceMotion: false)
        try expect((plainAvatar.layer?.sublayers ?? []).count == 1, "an idle with no effect should draw only the figure's layers")
    }

    /// Every bundled class whose idle carries an effect has all its art, and each effect track loops on its own length rather than
    /// the breathing's.
    @MainActor
    private static func testEveryBundledIdleEffectHasItsArtAndLoops() throws {
        for (classID, sprites) in TrackerAvatarSprites.bundled().sorted(by: { $0.key < $1.key }) {
            for layer in [TrackerAvatarLayer.behind, .front] {
                guard let track = sprites.animation.idle?.effect(layer) else {
                    continue
                }
                let missing = missingFrames(of: sprites).filter { $0.hasPrefix("idle effect") }
                try expect(missing.isEmpty, "the \(classID)'s idle \(layer.rawValue) effect should have all its art, missing: \(missing)")
                try expect(track.frame(at: track.seconds, looping: true) == track.steps[0].frame,
                           "the \(classID)'s idle \(layer.rawValue) effect should loop back to its first frame after \(track.seconds) s")
            }
        }
    }

    /// The necromancer's sprites load from the app bundle: his breathing plays its authored steps with their eyelid stencils,
    /// he never blinks, and all three spells have their frame art.
    @MainActor
    private static func testBundledNecromancerSpritesReadTheirAnimationFile() throws {
        guard let sprites = TrackerAvatarSprites.bundled()["necromancer"] else {
            throw TestFailure("the necromancer's sprites should load from the app bundle")
        }
        try expect(sprites.animation.idle?.blink == false, "the necromancer should not schedule a blink")
        try expect(sprites.animation.idle?.breathing?.frames.count == 7 && sprites.idleBreathingArt?.count == 7,
                   "the necromancer should load all seven breathing steps and their lid stencils")
        try expect(sprites.animation.fidgets.map(\.name) == ["cough"], "the necromancer should have the cough fidget")
        try expect(sprites.availableFidgets.count == 1, "the necromancer's fidget should have its art")
        try expect(TrackerAvatarPose.allCases.allSatisfy { sprites.canvasSize(for: $0) != nil }, "every pose should have the necromancer's art")
        try expect([.orb, .messenger, .wisp].allSatisfy { sprites.flight(for: $0) != nil && sprites.impact(for: $0) != nil },
                   "the necromancer should have the frame art of all three spells")
        try expect(sprites.handPoint(in: CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)) != nil,
                   "the necromancer's release should have a hand")
        let missing = missingFrames(of: sprites)
        try expect(missing.isEmpty, "every frame the necromancer's file plays should have its art, missing: \(missing)")
    }

    /// The shared bubble stays inside the avatar slot, above the banner at its sole. Every bundled
    /// class with an anchor is checked, and a fixture with one covers the path until a class ships one.
    @MainActor
    private static func testTheBubbleStaysInTheSlotAboveTheBanner() throws {
        for (classID, sprites) in TrackerAvatarSprites.bundled().sorted(by: { $0.key < $1.key })
        where sprites.animation.animation(for: .callingOut)?.bubble != nil {
            try expectBubbleClear(of: sprites, named: classID)
        }
        let leftTail = try bubbleFixture()
        let rightTail = try bubbleFixture(tail: "right")
        try expectBubbleClear(of: leftTail, named: "the bubble fixture")
        try expectBubbleClear(of: rightTail, named: "the mirrored bubble fixture")
        try expectMirroredBubbleKeepsItsBox(plain: leftTail, mirrored: rightTail)
    }

    /// A `tail: "right"` bubble is the same box at the same anchor as the default one, drawn flipped about its x; the default isn't.
    @MainActor
    private static func expectMirroredBubbleKeepsItsBox(plain: TrackerAvatarSprites, mirrored: TrackerAvatarSprites) throws {
        guard let plainPose = plain.animation.animation(for: .callingOut), let mirroredPose = mirrored.animation.animation(for: .callingOut),
              let plainRig = TrackerAvatarFrameRig(pose: .callingOut, placement: plainPose, sprites: plain),
              let mirroredRig = TrackerAvatarFrameRig(pose: .callingOut, placement: mirroredPose, sprites: mirrored) else {
            throw TestFailure("both bubble fixtures should draw calling out")
        }
        let slot = CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        plainRig.place(in: slot)
        mirroredRig.place(in: slot)
        try expect(plainPose.bubbleTail == .left && mirroredPose.bubbleTail == .right, "the fixtures should carry their tails")
        try expect(plainRig.bubble.frame == mirroredRig.bubble.frame, "a mirrored bubble should keep the unmirrored box, got \(mirroredRig.bubble.frame) vs \(plainRig.bubble.frame)")
        try expect(CATransform3DIsIdentity(plainRig.bubble.transform), "a left-tail bubble should be drawn as the art is")
        try expect(CATransform3DEqualToTransform(mirroredRig.bubble.transform, CATransform3DMakeScale(-1, 1, 1)), "a right-tail bubble should flip horizontally")
        try expect(mirroredRig.bubble.magnificationFilter == .nearest, "a mirrored bubble should stay unsmoothed")
    }

    /// A synthetic calling-out pose reaches out of the fixed slot and draws over the plate above it, while its sole meets the banner.
    @MainActor
    private static func testTallAvatarDrawsOverThePlatesWithoutChangingTheSlot() throws {
        let fixture = try TrackerAvatarOverflowFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.folder) }
        guard let idleFigureHeight = fixture.sprites.idleFigureHeight,
              let pose = fixture.sprites.animation.animation(for: .callingOut),
              let image = fixture.sprites.frame(.callingOut, .character, 1),
              let rows = TrackerAvatarSprites.opaqueRows(of: image) else {
            throw TestFailure("the synthetic tall pose should have a readable frame and idle figure")
        }
        let poseHeight = TrackerTagLayout.figureHeight(topRow: rows.lowerBound, footRow: pose.footRow)
        try expect(idleFigureHeight == 160, "the synthetic idle should be 160 px tall, got \(idleFigureHeight)")
        try expect(CGFloat(poseHeight) > TrackerAvatarMetrics.slotHeight, "the synthetic pose should extend above the reserved slot")
        try expect(TrackerAvatarMetrics.slotHeight == 175, "the avatar slot should keep its reserved height")

        let scale: CGFloat = 2
        let slotTop = TrackerAvatarOverflowFixture.slotTop
        let size = TrackerAvatarOverflowFixture.canvas
        let content = SelectedSessionTagContent(
            title: "Tall Pose Preview", id: "qm-preview", projectName: "preview", projectColor: NSColor(hex: 0x3434A8)
        )
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 0) {
            TrackerNameplateBackground(
                role: .master, color: AppPalette.inert, showsCursor: false, isRecoloring: false,
                statusColor: nil, ring: .none, text: EmptyView()
            )
            TrackerAvatarSlot(pose: .callingOut, sprites: fixture.sprites)
                .zIndex(1)
            SelectedSessionTag(content: content, onCopyID: { _ in })
                .zIndex(2)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(AppPalette.window.swiftUI))
        host.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size, scale: scale)
        defer { window.close() }
        window.contentView = host
        window.show()

        let overflow = CGFloat(poseHeight) - TrackerAvatarMetrics.slotHeight
        let bandHeight = Int(overflow * scale)
        let columns = Int(90 * scale)..<Int(170 * scale)
        let topBandStart = Int((slotTop - overflow) * scale)
        let topBandEnd = Int(slotTop * scale)
        let topBand = topBandStart..<topBandEnd
        func showsPose(_ bitmap: NSBitmapImageRep, in rows: Range<Int>) -> Bool {
            rows.contains { y in
                columns.contains { x in
                    guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return pixel.alphaComponent > 0.9 && pixel.redComponent > 0.8 && pixel.greenComponent < 0.2 && pixel.blueComponent < 0.15
                }
            }
        }
        var bitmap: NSBitmapImageRep?
        var view: TrackerAvatarView?
        try expect(waitUntil {
            bitmap = try? snapshot(host, size: size, scale: scale)
            view = ([host] + host.subviews.flatMap { descendants(of: $0) }).compactMap { $0 as? TrackerAvatarView }.first
            guard let bitmap else { return false }
            let oppositeTopBand = (bitmap.pixelsHigh - topBand.upperBound)..<(bitmap.pixelsHigh - topBand.lowerBound)
            return view != nil && (showsPose(bitmap, in: topBand) || showsPose(bitmap, in: oppositeTopBand))
        }, "the pose's top rows should draw over the plate above the slot")
        try expect(bitmap != nil, "the overlapping plate and avatar should render to a bitmap")
        try expect(view?.bounds.size == CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight),
                   "the avatar view should retain its reserved slot frame")
        try expect(view?.layer?.masksToBounds == false, "the avatar layer should leave its overflow visible")
        try expect(view?.hitTest(NSPoint(x: view?.bounds.midX ?? 0, y: view?.bounds.midY ?? 0)) == nil,
                   "the avatar should keep taking no clicks")

        try expect(bandHeight > 0, "the synthetic pose should have top rows outside the slot")
    }

    /// A real tracker with a synthetic pixel mark that crosses the foot row: its sole stays visible while the id tab
    /// hides its lower pixels. The tall-pose test separately checks that the avatar still draws above the plates.
    private static func testTheBannerCoversArtBelowTheSoleButKeepsTheSoleVisible() throws {
        let art = try TrackerAvatarOverflowFixture.make()
        defer { try? FileManager.default.removeItem(at: art.folder) }
        let fixture = try TrackerFixture(masters: 1, shells: 2, viewed: "master-0", height: 700, sessionClass: "wizard")
        defer { fixture.close() }
        guard let avatar = descendants(of: fixture.view).compactMap({ $0 as? TrackerAvatarView }).first,
              let pose = art.sprites.animation.animation(for: .callingOut),
              let marker = NSColor(cgColor: TrackerAvatarOverflowFixture.markerColor) else {
            throw TestFailure("the tracker should have its avatar slot and synthetic marker art")
        }
        avatar.sprites = art.sprites
        avatar.configure(pose: .callingOut, beat: 0, finish: nil, reduceMotion: true)
        let slot = fixture.view.convert(avatar.bounds, from: avatar)
        let sole = fixture.view.isFlipped ? slot.maxY : fixture.size.height - slot.minY
        let scale: CGFloat = 2
        let column = Int((slot.minX + slot.width / 2 - CGFloat(pose.bodyColumn) + 7) * scale)
        let soleRow = Int(sole * scale) - 1
        let hangingRow = Int((sole + 2) * scale)
        var probe: PixelProbe?
        try expect(waitUntil {
            guard let bitmap = try? snapshot(fixture.view, size: fixture.size, scale: scale) else { return false }
            probe = PixelProbe(bitmap: bitmap, height: bitmap.pixelsHigh)
            return probe?.isColor(column, soleRow, marker) == true
        }, "the sprite's last sole row should remain visible directly above the banner")
        try expect(probe?.isColor(column, hangingRow, AppPalette.panel) == true,
                   "the banner's id tab should cover the sprite pixels hanging below the sole")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    /// The cleric's sprites with a bubble anchor beside his head on the right, read the way a class's file would carry one.
    @MainActor
    private static func bubbleFixture(tail: String? = nil) throws -> TrackerAvatarSprites {
        guard let folder = AppSymbolStyle.resourceBundle().resourceURL?.appendingPathComponent("Sprites/cleric", isDirectory: true),
              let data = try? Data(contentsOf: folder.appendingPathComponent("animation.json")),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var poses = json["poses"] as? [String: Any],
              var calling = poses["11-calling-out"] as? [String: Any] else {
            throw TestFailure("the cleric's calling-out pose should read as JSON")
        }
        var anchor: [String: Any] = ["x": 52, "y": 24]
        anchor["tail"] = tail
        calling["bubble"] = anchor
        poses["11-calling-out"] = calling
        json["poses"] = poses
        let animation = try TrackerAvatarAnimation(data: JSONSerialization.data(withJSONObject: json))
        return TrackerAvatarSprites(classID: "cleric", animation: animation, folder: folder)
    }

    /// Checks the bubble the calling-out rig places for `sprites`, as the slot sees it (top left origin): inside the slot and under the tag.
    @MainActor
    private static func expectBubbleClear(of sprites: TrackerAvatarSprites, named name: String) throws {
        guard let placement = sprites.animation.animation(for: .callingOut),
              sprites.bubble != nil, let rig = TrackerAvatarFrameRig(pose: .callingOut, placement: placement, sprites: sprites) else {
            throw TestFailure("\(name) should draw its calling out with the shared bubble")
        }
        let slot = CGRect(x: 0, y: 0, width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight)
        rig.place(in: slot)
        try expect(rig.root.sublayers?.last === rig.bubble, "\(name)'s bubble should draw over the figure and its effects")
        // Layers measure from the bottom left: the bubble is in the root's space, and the root in the slot's.
        let bubble = rig.bubble.frame.offsetBy(dx: rig.root.frame.minX, dy: rig.root.frame.minY)
        let bubbleTop = slot.height - bubble.maxY
        let bubbleBottom = slot.height - bubble.minY
        try expect(bubble.width > 0 && bubble.height > 0, "\(name)'s bubble should have a frame")
        try expect(bubble.minX >= slot.minX && bubble.maxX <= slot.maxX && bubbleTop >= slot.minY && bubbleBottom <= slot.maxY,
                   "\(name)'s bubble should sit inside the slot, got \(bubble)")
        try expect(bubbleBottom <= slot.height, "\(name)'s bubble should stay above the banner at the slot's bottom, got its bottom at \(bubbleBottom)")
    }

    /// Each bundled class's idle figure is measured from its own art, against its foot line, and the slot reserves the tallest one
    /// rounded up to the 5 pt step.
    @MainActor
    private static func testTheBundledIdleFiguresSetTheSlot() throws {
        let sprites = TrackerAvatarSprites.bundled()
        for (classID, figure) in [("barbarian", 166), ("bard", 157), ("cleric", 155), ("druid", 153), ("fighter", 161), ("necromancer", 161), ("paladin", 173), ("ranger", 153), ("rogue", 129), ("sorcerer", 150), ("wizard", 150)] {
            try expect(sprites[classID]?.idleFigureHeight == figure,
                       "the \(classID)'s idle figure should be \(figure) px, got \(String(describing: sprites[classID]?.idleFigureHeight))")
        }
        let tallest = sprites.values.compactMap(\.idleFigureHeight).max() ?? 0
        try expect(TrackerAvatarMetrics.tallestFigureHeight == tallest, "the tallest figure should be \(tallest) px, got \(TrackerAvatarMetrics.tallestFigureHeight)")
        try expect(TrackerAvatarMetrics.slotHeight == 175, "the slot should reserve the tallest figure rounded up to 5, got \(TrackerAvatarMetrics.slotHeight)")
    }

    /// Masters and workers reserve one fixed-width banner and avatar slot, with or without shells or class art.
    private static func testTheAvatarStandsOnTheFullWidthBannerAboveTheShells() throws {
        for shells in [0, 3] {
            for sessionClass in ["wizard", "paladin", ""] {
                for viewed in ["master-0", "worker-0"] {
                    let fixture = try TrackerFixture(masters: 1, shells: shells, viewed: viewed, height: 700, sessionClass: sessionClass, workers: 1)
                    defer { fixture.close() }
                    guard let avatar = descendants(of: fixture.view).compactMap({ $0 as? TrackerAvatarView }).first else {
                        throw TestFailure("the tracker should reserve an avatar slot, including for a class without art")
                    }
                    let shellHeight = CGFloat(shells) * TrackerShellMetrics.rowHeight
                    let bannerBottom = fixture.size.height - TrackerListMetrics.verticalPadding - shellHeight - (shells > 0 ? Space.section : 0)
                    let bannerTop = bannerBottom - SelectedSessionTagMetrics.height
                    let slot = fixture.view.convert(avatar.bounds, from: avatar)
                    let sole = fixture.view.isFlipped ? slot.maxY : fixture.size.height - slot.minY
                    try expect(abs(sole - bannerTop) < 1, "\(sessionClass) with \(shells) shells: the sole should touch the banner top at \(bannerTop), got \(sole)")
                    try expect(slot.size == CGSize(width: TrackerAvatarMetrics.slotWidth, height: TrackerAvatarMetrics.slotHeight),
                               "the reserved slot should keep the same size for every class")
                    try expect(abs(slot.minX - TrackerListMetrics.sidePadding) < 1, "the avatar and banner should start at the plates' leading inset")

                    let probe = try fixture.probe()
                    let left = Int(TrackerListMetrics.sidePadding)
                    let tabMiddle = Int(bannerTop + SelectedSessionTagMetrics.tabHeight / 2)
                    try expect(probe.isColor(left + Int(Space.item), tabMiddle, AppPalette.panel), "the banner's id tab should sit directly under the slot")
                    try expect(probe.isColor(left + Int(Space.row) - 1, tabMiddle, AppPalette.window), "the id tab should stay inset 5pt")
                    let barMiddle = Int(bannerBottom - SelectedSessionTagMetrics.borderWidth - SelectedSessionTagMetrics.barHeight / 2)
                    let color = TrackerNameplateColor.barLightness(AppPalette.displayColor("indigo") ?? AppPalette.muted)
                    for x in [left + Int(Space.item), left + Int(TrackerAvatarMetrics.slotWidth - Space.item)] {
                        try expect(probe.isColor(x, barMiddle, color), "\(sessionClass) with \(shells) shells: the banner's bar should span the full 260pt plate width at \(x), \(barMiddle)")
                    }
                    let tracker = TrackerRenderer.tracker(fixture.store.snapshot)
                    let attached = SelectedSessionTagContent.make(currentTerminalSessionID: viewed, tracker: tracker)
                    try expect(attached?.title == viewed && attached?.id == viewed && attached?.projectName == "Repo",
                               "an attached plate should keep its own banner details, including without class art")
                    if shells > 0 {
                        let shellTop = fixture.size.height - TrackerListMetrics.verticalPadding - shellHeight
                        try expect(abs(shellTop - bannerBottom - Space.section) < 1, "the shells should start 20pt below the banner")
                        try expect(probe.clearBand(above: Int(shellTop)), "the shell gap should stay clear below the banner's shadow")
                    }
                }
            }
        }

        for title in ["A", String(repeating: "A long title ", count: 20)] {
            let tag = NSHostingView(rootView: SelectedSessionTag(
                content: SelectedSessionTagContent(title: title, id: "qm-example", projectName: "Example", projectColor: AppPalette.muted),
                onCopyID: { _ in }
            ))
            try expect(tag.fittingSize.width == TrackerAvatarMetrics.slotWidth, "short and long titles should both reserve a 260pt banner")
        }
    }

    /// Shells, unknown ids and no attachment remove the whole footer, returning its reserved room to the plates.
    private static func testShellsAndNoAttachmentGiveTheAvatarSpaceBackToTheList() throws {
        for shells in [0, 3] {
            for viewed: String? in ["shell-0", nil, "unknown-session"] {
                let fixture = try TrackerFixture(masters: 14, shells: shells, viewed: viewed, height: 700, sessionClass: "wizard")
                defer { fixture.close() }
                try expect(!descendants(of: fixture.view).contains { $0 is TrackerAvatarView },
                           "\(String(describing: viewed)): no avatar slot should remain without an attached plate")
                let tracker = TrackerRenderer.tracker(fixture.store.snapshot)
                try expect(SelectedSessionTagContent.make(currentTerminalSessionID: viewed, tracker: tracker) == nil,
                           "\(String(describing: viewed)): no banner should remain without an attached plate")
                let shellHeight = CGFloat(shells) * TrackerShellMetrics.rowHeight
                let listHeight = fixture.size.height - shellHeight - TrackerListMetrics.verticalPadding - (shells > 0 ? Space.section : 0)
                try expect(fixture.scrollView(height: listHeight) != nil,
                           "\(String(describing: viewed)): plates should fill the freed avatar and banner space up to \(listHeight)")
                if shells > 0 {
                    let shellTop = fixture.size.height - TrackerListMetrics.verticalPadding - shellHeight
                    let probe = try fixture.probe()
                    try expect(probe.clearBand(above: Int(shellTop)), "the plates should leave 20pt above the pinned shells")
                    guard let shellScroll = fixture.scrollView(height: shellHeight) else { throw TestFailure("the shells should keep their own section") }
                    let section = fixture.view.convert(shellScroll.bounds, from: shellScroll)
                    let bottom = fixture.view.isFlipped ? section.maxY : fixture.size.height - section.minY
                    try expect(abs(bottom - (fixture.size.height - TrackerListMetrics.verticalPadding)) < 1,
                               "the shells should stay 20pt from the bottom without an attached plate")
                    if viewed == "shell-0" {
                        try expect(probe.filledShellRows.contains(Int(shellTop)), "the selected first shell should stay at the pinned section's top")
                    }
                }
            }
        }
        for role in ["tmux", "orphan"] {
            let fixture = try TrackerFixture(masters: 1, shells: 1, viewed: "shell-0", height: 700, sessionClass: "wizard", shellRole: role)
            defer { fixture.close() }
            try expect(!descendants(of: fixture.view).contains { $0 is TrackerAvatarView }, "an attached \(role) should reserve no avatar slot")
            let tracker = TrackerRenderer.tracker(fixture.store.snapshot)
            try expect(SelectedSessionTagContent.make(currentTerminalSessionID: "shell-0", tracker: tracker) == nil, "an attached \(role) should have no banner")
        }
    }

    /// The frames a class's file plays that have no art, as `pose layer fN` names, and the spells' frames and stills.
    @MainActor
    private static func missingFrames(of sprites: TrackerAvatarSprites) -> [String] {
        var missing: [String] = []
        for frame in sprites.animation.idle?.breathing?.frames ?? [] where sprites.idleBreathingFrame(frame.file) == nil {
            missing.append(frame.file)
        }
        for layer in [TrackerAvatarLayer.behind, .front] {
            for step in sprites.animation.idle?.effect(layer)?.steps ?? [] where sprites.frame(.idle, layer, step.frame) == nil {
                missing.append("idle effect \(layer.rawValue) f\(step.frame)")
            }
        }
        for pose in TrackerAvatarPose.allCases {
            guard let poseAnimation = sprites.animation.animation(for: pose) else {
                continue
            }
            for block in [poseAnimation.loop, poseAnimation.enter, poseAnimation.finish, poseAnimation.once].compactMap({ $0 }) {
                for layer in TrackerAvatarLayer.allCases {
                    for step in block.track(for: layer)?.steps ?? [] where sprites.frame(pose, layer, step.frame) == nil {
                        missing.append("\(pose.resourceName) \(layer.rawValue) f\(step.frame)")
                    }
                }
            }
        }
        for spell in TrackerSpellFlight.Spell.allCases {
            let animation = sprites.animation.spell(spell)
            for part in TrackerSpellPart.allCases {
                let track = part == .flight ? animation?.flight : animation?.impact
                // A part with a track plays one frame per step; one without keeps its still.
                for number in track?.steps.map(\.frame) ?? [nil] where sprites.spellFrame(spell, part, number) == nil {
                    missing.append("\(spell.resourceName) \(part.rawValue) \(number.map { "f\($0)" } ?? "still")")
                }
            }
        }
        return missing
    }

    @MainActor
    /// A bundled class whose idle stands still, breathing and blinking between fidgets: the wizard. The bard's idle is a strumming
    /// loop, so the idle-layer tests read the wizard.
    private static func stillIdleSprites() throws -> TrackerAvatarSprites {
        guard let sprites = TrackerAvatarSprites.bundled()["wizard"] else {
            throw TestFailure("the wizard's sprites should load from the app bundle")
        }
        return sprites
    }

    /// A class folder for the render tests, in a temporary directory: the wizard's `animation.json` with calling out's loop made 1 frame
    /// for the character and 8 frames for the front, an enter of f2 and a finish of f3 on the character, and a summoning of three frames
    /// with a ground layer. The frames the loops, the enter, the finish and the summoning need are each a solid square.
    @MainActor
    private static func syntheticClassFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-class-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let classFile = try Data(contentsOf: try stillIdleAnimationFile())
        guard var json = try JSONSerialization.jsonObject(with: classFile) as? [String: Any],
              var poses = json["poses"] as? [String: Any],
              var calling = poses["11-calling-out"] as? [String: Any],
              var summoning = poses["09-summoning"] as? [String: Any] else {
            throw TestFailure("the wizard's animation.json should read as a JSON object")
        }
        let summoningIn: [[Any]] = [[2, 0.18], [1, 0.36]]
        let summoningOut: [[Any]] = [[1, 0.18], [3, 0.36]]
        summoning["enter"] = ["character": summoningIn, "behind": summoningIn]
        summoning["loop"] = ["character": [[3, 0.46]], "behind": [[3, 0.46]]]
        summoning["finish"] = ["character": summoningOut, "behind": summoningOut]
        summoning.removeValue(forKey: "front")
        poses["09-summoning"] = summoning
        let eightFrames = (1...8).map { [$0, 0.125] as [Any] }
        calling["loop"] = ["character": [[1, 0.25]], "front": eightFrames]
        calling["enter"] = ["character": [[2, 0.25]]]
        calling["finish"] = ["character": [[3, 0.25]]]
        poses["11-calling-out"] = calling
        // A release with an entrance (frames 1 and 2) before its strike (3) and follow-through (4): it names its strike frame.
        guard var release = poses["08-release"] as? [String: Any] else {
            throw TestFailure("the wizard's file should have a release")
        }
        release["once"] = ["character": [[1, 0.1], [2, 0.1], [3, 0.2], [4, 0.1]]]
        release["strike_frame"] = 3
        poses["08-release"] = release
        json["poses"] = poses
        json["spells"] = [
            "S6-returning-wisp": [
                "flight": [[1, 0.1], [2, 0.1], [3, 0.2]],
                "impact": [[1, 0.1], [2, 0.1]],
                "anchor": ["x": 7, "y": 2],
            ],
            "S2-messenger": ["flight": [[1, 0.1], [2, 0.1]]],
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("animation.json"))
        for number in 1...3 {
            try writeSolidFrame(Double(number) / 10, to: folder.appendingPathComponent("09-summoning-f\(number).png"))
            try writeSolidFrame(Double(number) / 10 + 0.4, to: folder.appendingPathComponent("09-summoning-behind-f\(number).png"))
        }
        try writeSolidFrame(0.1, to: folder.appendingPathComponent("11-calling-out-f1.png"))
        try writeSolidFrame(0.2, to: folder.appendingPathComponent("11-calling-out-f2.png"))
        try writeSolidFrame(0.3, to: folder.appendingPathComponent("11-calling-out-f3.png"))
        for number in 1...4 {
            try writeSolidFrame(Double(number) / 10, to: folder.appendingPathComponent("08-release-f\(number).png"))
        }
        // The spells' art, each canvas its own size: the wisp's flight 8 by 4 and its impact 6 by 6, the messenger's flight 6 by 4, and
        // the stills 4 by 4.
        for number in 1...3 {
            try writeSolidFrame(Double(number) / 10, width: 8, height: 4, to: folder.appendingPathComponent("S6-returning-wisp-flight-f\(number).png"))
        }
        for number in 1...2 {
            try writeSolidFrame(Double(number) / 10, width: 6, height: 6, to: folder.appendingPathComponent("S6-returning-wisp-impact-f\(number).png"))
            try writeSolidFrame(Double(number) / 10, width: 6, height: 4, to: folder.appendingPathComponent("S2-messenger-flight-f\(number).png"))
        }
        for still in ["S2-messenger-impact", "S1-summoning-orb-flight", "S1-summoning-orb-impact"] {
            try writeSolidFrame(0.5, width: 4, height: 4, to: folder.appendingPathComponent("\(still).png"))
        }
        for number in 1...8 {
            try writeSolidFrame(Double(number) / 10, to: folder.appendingPathComponent("11-calling-out-front-f\(number).png"))
        }
        return folder
    }

    @MainActor
    private static func stillIdleAnimationFile() throws -> URL {
        guard let url = AppSymbolStyle.resourceBundle().url(forResource: "animation", withExtension: "json", subdirectory: "Sprites/wizard") else {
            throw TestFailure("the wizard's animation.json should be in the app bundle")
        }
        return url
    }

    private static func writeSolidFrame(_ red: CGFloat, width: Int = 2, height: Int = 2, to url: URL) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TestFailure("a test frame should be drawable")
        }
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw TestFailure("a test frame should be made")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestFailure("a test frame should be written to \(url.lastPathComponent)")
        }
    }

    private static func testMotionTokensShareOneEasingAndFollowReduceMotion() throws {
        defer { Motion.reducesMotion = { false } }
        Motion.reducesMotion = { false }
        for step in [MotionStep.fast, .standard] {
            try expect(Motion.duration(step) == step.seconds * Motion.slowdown, "\(step) should run its own length")
            try expect(Motion.animation(step) != nil, "\(step) should animate in SwiftUI")
        }
        func controls(of function: CAMediaTimingFunction) -> [Float] {
            var points = [Float](repeating: 0, count: 2)
            var controls: [Float] = []
            for index in 1...2 {
                function.getControlPoint(at: index, values: &points)
                controls += points
            }
            return controls
        }
        let curve = MotionEasing.controlPoints
        try expect(controls(of: Motion.timingFunction) == [Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2)], "the Core Animation easing should be Core's control points, got \(controls(of: Motion.timingFunction))")
        let breathing = MotionEasing.breathingControlPoints
        try expect(controls(of: Motion.breathingTimingFunction) == [Float(breathing.x1), Float(breathing.y1), Float(breathing.x2), Float(breathing.y2)], "the breathing easing should be Core's breathing control points, got \(controls(of: Motion.breathingTimingFunction))")
        var configured: (duration: TimeInterval, curve: CAMediaTimingFunction?)?
        NSAnimationContext.runAnimationGroup { context in
            Motion.configure(context, .fast)
            configured = (context.duration, context.timingFunction)
        }
        try expect(configured?.duration == MotionStep.fast.seconds * Motion.slowdown, "an AppKit animation should run the step's length, got \(String(describing: configured?.duration))")
        try expect(configured?.curve === Motion.timingFunction, "an AppKit animation should take the shared easing")

        Motion.reducesMotion = { true }
        for step in [MotionStep.fast, .standard] {
            try expect(Motion.duration(step) == 0, "\(step) should not run under Reduce Motion")
            try expect(Motion.animation(step) == nil && Motion.animation(step, after: .fast) == nil, "\(step) should not animate in SwiftUI under Reduce Motion")
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

    private static func testInstalledBundleStartsTheStableLink() throws {
        let fixture = try appBackendFixture()
        let installed = fixture.stateRoot.appendingPathComponent("bin/versions/v1-test-0123456789ab/qm")
        let stable = fixture.stateRoot.appendingPathComponent("bin/current/qm")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable("#!/bin/sh\necho installed qm\n", to: installed)
        try FileManager.default.createSymbolicLink(atPath: stable.path, withDestinationPath: installed.path)
        let backend = AppBackendResolver.resolve(arguments: [], environment: fixture.environment,
                                                workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        // The link path itself, not its target: the daemon is canonical because it runs as the link.
        try expect(backend.source == .stable && backend.executablePath == stable.path,
                   "installed bundle should start the stable link, got \(backend.source) \(backend.executablePath)")
        try expect(backend.command("start")?.arguments == ["daemon", "start"], "stable link should use daemon start")
    }

    private static func testBundleWithoutAResolvingStableLinkBootstrapsWithItsQM() throws {
        let fixture = try appBackendFixture()
        let stable = fixture.stateRoot.appendingPathComponent("bin/current/qm")
        try FileManager.default.createDirectory(at: stable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: stable.path, withDestinationPath: fixture.root.appendingPathComponent("gone/qm").path)
        let backend = AppBackendResolver.resolve(arguments: [], environment: fixture.environment,
                                                workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        try expect(backend.source == .bundled && backend.executablePath == fixture.qm.path,
                   "a dangling stable link should fall back to the bundle's qm, got \(backend.source) \(backend.executablePath)")
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

    /// A record miss (after every dropped connection) hashes the daemon binary only when it changed on disk.
    private static func testDaemonRecordReusesTheBinaryHashUntilTheBinaryChanges() throws {
        let fixture = try appBackendFixture()
        let binary = fixture.root.appendingPathComponent("daemon-qm")
        try Data("first build".utf8).write(to: binary)
        let json = try String(data: JSONSerialization.data(withJSONObject: [
            "running": true, "root": fixture.stateRoot.path, "identity": "canonical",
            "socket": fixture.root.appendingPathComponent("daemon.sock").path,
            "executable": binary.path, "shim_directory": fixture.root.appendingPathComponent("daemon-shims").path,
            "build": "first build", "generation": 1, "accepting": true,
        ]), encoding: .utf8) ?? ""
        try writeExecutable("#!/bin/sh\nprintf '%s\\n' '\(json)'\n", to: fixture.qm)
        let config = LaunchConfiguration.load(environment: fixture.environment,
                                              workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        let previous = AppBackendEnvironment.current
        defer { if let previous { AppBackendEnvironment.activate(previous) } }
        AppBackendEnvironment.activate(config.backend)
        var hashed: [String] = []
        let connection = DaemonConnection(config: config, hashFile: { path in
            hashed.append(path)
            return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        })

        _ = try connection.record()
        connection.invalidate()
        _ = try connection.record()
        try expect(hashed == [binary.path], "an unchanged binary should be hashed once, got \(hashed.count) hashes")

        try Data("second, longer build".utf8).write(to: binary)
        connection.invalidate()
        _ = try connection.record()
        try expect(hashed.count == 2, "a changed binary should be hashed again, got \(hashed.count) hashes")
    }

    private static func testTmuxStartupScriptScopesAppBackendEnvironmentToSession() throws {
        let route = try TmuxRoute(sessionID: "qm-test", label: "default", configFiles: [], live: true, createdUnix: 1)
        let env = ["SHELL": "/tmp/custom shell/zsh", "PATH": "/usr/bin", "QUESTMASTER_APP": "1"]
        let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", route: route, environment: env)
        let checkIndex = try substringIndex(in: script, "qm_tmux has-session -t \"=$session\"")
        let syncIndex = try substringIndex(in: script, "qm_tmux set-environment -t \"=$session\" 'QUESTMASTER_APP'")
        let attachIndex = try substringIndex(in: script, "qm_tmux attach-session -t \"=$session\"")
        let markerIndex = try substringIndex(in: script, "printf '\\033]0;\(TerminalDetachSignal.markerTitle)\\007'")
        let unsetIndex = try substringIndex(in: script, "unset QUESTMASTER_SESSION TMUX TMUX_PANE TMUX_TMPDIR || true")
        try expect(checkIndex < syncIndex && syncIndex < attachIndex && attachIndex < markerIndex && markerIndex < unsetIndex, "script should check, sync, attach, mark detach, then clear env")
        try expect(script.contains("exec '/tmp/custom shell/zsh' -l"), "detach should start configured login shell")
        try expect(!script.contains("set-environment -g"), "startup should not write global environment")
        let fallback = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", route: route, environment: [:])
        try expect(fallback.contains("exec '/bin/zsh' -l"), "missing shell should fall back to zsh")
    }

    private static func testTmuxStartupScriptTargetsOnlyTheExactSession() throws {
        let route = try TmuxRoute(sessionID: "qm-123", label: "default", configFiles: [], live: true, createdUnix: 1)
        let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", route: route, environment: [:])
        try expect(script.contains("session='qm-123'"), "startup script should name its session")
        let targetLines = script.split(separator: "\n").filter { $0.contains(" -t ") }
        try expect(!targetLines.isEmpty, "startup script should address tmux sessions with -t")
        for line in targetLines {
            try expect(line.contains(" -t \"=$session\""), "startup script should use exact targets: \(line)")
        }
    }

    private static func testTmuxStartupScriptNeverRespawnsPlaceholder() throws {
        let route = try TmuxRoute(sessionID: "qm-123", label: "default", configFiles: [], live: true, createdUnix: 1)
        let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", route: route, environment: ["SHELL": "/bin/sh"])
        try expect(!script.contains("new-session") && !script.contains("respawn-pane"), "startup script should not create or respawn a session")
        try expect(script.contains("exit 1; fi"), "missing selected session should fail")
        if let path = ProcessInfo.processInfo.environment["QUESTMASTER_TEST_STARTUP_SCRIPT_DUMP"] {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func testTmuxStartupScriptWritesNoGlobalEnvironment() throws {
        let route = try TmuxRoute(sessionID: "qm-123", label: "default", configFiles: [], live: true, createdUnix: 1)
        for values in [["HOME": "/tmp/example", "QUESTMASTER_APP": "1"], [:]] {
            let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", route: route, environment: values)
            try expect(!script.contains("set-environment -g"), "startup script should write no global tmux environment")
        }
    }

    private static func testTmuxStartupScriptDoesNotStartServer() throws {
        let route = try TmuxRoute(sessionID: "qm-123", label: "questmaster", configFiles: ["/tmp/user.conf"], live: true, createdUnix: 1)
        let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", route: route, environment: [:])
        try expect(!script.contains("new-session") && !script.contains("server_path="), "startup script should not start a server")
        try expect(script.contains("(cd / && '/usr/bin/tmux' -L 'questmaster' -f '/tmp/user.conf'"), "script should run routed tmux from root")
        try expect(script.contains("unset TMUX TMUX_PANE TMUX_TMPDIR"), "script should clear caller's tmux env")
    }

    private static func testTmuxClientCallsTargetTheExactSession() throws {
        let route = try TmuxRoute(sessionID: "qm-123", label: "default", configFiles: [], live: true, createdUnix: 1)
        let syncArguments = TerminalTmuxClientProcess.sessionEnvironmentSyncArguments(route: route, environment: ["HOME": "/tmp/example"])
        let syncTargets = zip(syncArguments, syncArguments.dropFirst()).filter { $0.0 == "-t" }.map(\.1)
        try expect(!syncTargets.isEmpty && syncTargets.allSatisfy { $0 == "=qm-123" }, "environment sync should target exact session")
        try expect(!syncArguments.contains("-g"), "environment sync should not write global env")
        let switchArguments = TerminalTmuxClientProcess.switchClientArguments(route: route, clientName: "/dev/ttys001")
        try expect(Array(switchArguments.suffix(2)) == ["-t", "=qm-123"], "switch-client should target exact session")
        let editorArguments = TerminalTmuxClientProcess.editorWindowArguments(route: route, path: "/tmp/a.md", shell: "/bin/zsh")
        try expect(Array(editorArguments[2...4]) == ["new-window", "-t", "=qm-123"], "editor should target exact session")
    }

    private static func testStartupScriptPrefixesEveryTmuxCall() throws {
        let route = try TmuxRoute(sessionID: "qm-test", label: "questmaster", configFiles: ["/tmp/config.conf"], live: true, createdUnix: 1)
        let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", route: route, environment: [:])
        try expect(script.contains("qm_tmux()"), "startup script should define a routed tmux function")
        try expect(script.contains("'/usr/bin/tmux' -L 'questmaster' -f '/tmp/config.conf' \"$@\""), "function should pass route arguments separately")
        for line in script.split(separator: "\n") where line.contains("has-session") || line.contains("set-environment") || line.contains("show-environment") || line.contains("attach-session") {
            try expect(line.contains("qm_tmux "), "startup tmux call should use its routed function: \(line)")
        }
    }

    private static func testStartupScriptNeverCreatesSessions() throws {
        let route = try TmuxRoute(sessionID: "qm-test", label: "default", configFiles: [], live: true, createdUnix: 1)
        let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", route: route, environment: [:])
        try expect(!script.contains("new-session") && !script.contains("respawn-pane") && !script.contains("sleep 2147483647"), "attach must not create a placeholder")
        try expect(script.contains("has-session") && script.contains("exit 1"), "missing session should fail visibly")
    }

    private static func testStartupScriptQuotesConfigPaths() throws {
        let route = try TmuxRoute(sessionID: "qm-test", label: "questmaster", configFiles: ["/tmp/a b'c.conf"], live: true, createdUnix: 1)
        let script = tmuxStartupScript(tmuxPath: "/usr/bin/tmux", route: route, environment: [:])
        try expect(script.contains("-f '/tmp/a b'\\''c.conf'"), "config path should be quoted as one shell word")
    }

    private static func testTmuxClientCallsUseRoute() throws {
        let route = try TmuxRoute(sessionID: "qm-test", label: "questmaster", configFiles: ["/tmp/config.conf"], live: true, createdUnix: 1)
        let prefix = ["-L", "questmaster", "-f", "/tmp/config.conf"]
        try expect(TerminalTmuxClientProcess.listClientsArguments(route: route).starts(with: prefix), "list-clients should use route")
        try expect(TerminalTmuxClientProcess.sessionEnvironmentSyncArguments(route: route, environment: [:]).starts(with: prefix), "environment sync should use route")
        try expect(TerminalTmuxClientProcess.switchClientArguments(route: route, clientName: "/dev/ttys001").starts(with: prefix), "switch-client should use route")
        try expect(TerminalTmuxClientProcess.editorWindowArguments(route: route, path: "/tmp/a.md", shell: "/bin/zsh").starts(with: prefix), "editor should use route")
    }

    private static func testCrossServerSwitchCreatesSurface() throws {
        try expect(TmuxRoute.surfaceDecision(attachedLabel: "default", targetLabel: "questmaster", clientAttached: true, sessionReappeared: false) == .newSurface, "cross-server switch should replace surface")
    }

    private static func testSameServerSwitchReusesClient() throws {
        try expect(TmuxRoute.surfaceDecision(attachedLabel: "default", targetLabel: "default", clientAttached: true, sessionReappeared: false) == .reuseClient, "same-server switch should reuse client")
    }

    private static func testUnknownMethodFailsAttach() throws {
        let response = #"{"protocol_version":3,"type":"response","ok":false,"error":"unknown method \"tmux.routes\""}"#
        let decodedError: Error
        do {
            _ = try UnixSocketMutationClient.decodeAck(Data(response.utf8))
            throw TestFailure("older daemon should fail route lookup")
        } catch {
            decodedError = error
        }
        guard let serveError = decodedError as? ServeClientError,
              case .unknownMethod("tmux.routes") = serveError else {
            throw TestFailure("unknown-method response should decode as a typed error")
        }
        let routeError = UnixSocketMutationClient.tmuxRouteError(decodedError)
        guard case TmuxRouteError.unsupportedDaemon = routeError else {
            throw TestFailure("tmux route lookup should map an older daemon to an explicit attach error")
        }
        final class FailingRoutes: ServeTmuxRouting {
            let error: Error
            init(_ error: Error) { self.error = error }
            func fetchTmuxRoutes(sessionIDs: [String], live: Bool, completion: @escaping (Result<[TmuxRoute], Error>) -> Void) {
                completion(.failure(error))
            }
        }
        final class CountingHost: TerminalPaneHosting {
            let view = NSView()
            var tmuxSessionID: String? { nil }
            var onFocusRequested: (() -> Void)?
            var onDetach: (() -> Void)?
            var cellMetrics: TerminalCellMetrics { .unavailable }
            var onCellMetricsChanged: (() -> Void)?
            var connects = 0
            var routedConnects = 0
            func start() {}
            func stop() {}
            func focus(in window: NSWindow?) {}
            func connect(to config: TerminalLaunchConfig, completion: @escaping (Result<String?, Error>) -> Void) {
                connects += 1
                if config.route != nil { routedConnects += 1 }
            }
        }
        let config = LaunchConfiguration(
            daemonSocketOverride: nil, startDaemon: false, tmuxSession: nil,
            disableTmux: false, workingDirectory: "/tmp",
            backend: AppBackend(stateRoot: "/tmp/example-state", executablePath: "", source: .unresolved,
                                workingDirectory: "/tmp", devWorktree: nil)
        )
        let host = CountingHost()
        var shownError: String?
        let controller = TerminalSessionController(
            config: config, runtimeStore: RuntimeStore(sourceLabel: "test"), routeClient: FailingRoutes(routeError),
            terminalShell: { nil }, updateWindowTitle: { _ in }, focusTerminal: {}, render: {},
            showMutationFailure: { _, _ in }, showMutationError: { _, error in shownError = error.localizedDescription },
            showTerminalEngineFailure: { _ in }, onFocusRequested: {}
        )
        controller.installPlaceholder(host)
        controller.switchTerminal(to: "qm-example")
        try expect(waitUntil { shownError != nil }, "route error should reach attach UI")
        try expect(shownError?.contains("tmux.routes") == true && host.routedConnects == 0 && host.connects == 1,
                   "older daemon should show an attach error and open the local shell without guessing a server")
    }

    private static func testCachedRouteAttachesBeforeRefresh() throws {
        final class Routes: ServeTmuxRouting {
            var pending: [(Result<[TmuxRoute], Error>) -> Void] = []
            func fetchTmuxRoutes(sessionIDs: [String], live: Bool, completion: @escaping (Result<[TmuxRoute], Error>) -> Void) {
                pending.append(completion)
            }
        }
        final class Host: TerminalPaneHosting {
            let view = NSView()
            var tmuxSessionID: String? { nil }
            var onFocusRequested: (() -> Void)?
            var onDetach: (() -> Void)?
            var cellMetrics: TerminalCellMetrics { .unavailable }
            var onCellMetricsChanged: (() -> Void)?
            var labels: [String] = []
            func start() {}
            func stop() {}
            func focus(in window: NSWindow?) {}
            func connect(to config: TerminalLaunchConfig, completion: @escaping (Result<String?, Error>) -> Void) {
                labels.append(config.route?.label ?? "local")
                completion(.success(config.tmuxSession))
            }
        }
        let config = LaunchConfiguration(
            daemonSocketOverride: nil, startDaemon: false, tmuxSession: nil,
            disableTmux: false, workingDirectory: "/tmp",
            backend: AppBackend(stateRoot: "/tmp/example-state", executablePath: "", source: .unresolved,
                                workingDirectory: "/tmp", devWorktree: nil)
        )
        let routes = Routes()
        let host = Host()
        let controller = TerminalSessionController(
            config: config, runtimeStore: RuntimeStore(sourceLabel: "test"), routeClient: routes,
            terminalShell: { nil }, updateWindowTitle: { _ in }, focusTerminal: {}, render: {},
            showMutationFailure: { _, _ in }, showMutationError: { _, _ in },
            showTerminalEngineFailure: { _ in }, onFocusRequested: {}
        )
        controller.installPlaceholder(host)
        let legacy = try TmuxRoute(sessionID: "qm-example", label: "default", configFiles: [], live: true, createdUnix: 1)
        let named = try TmuxRoute(sessionID: "qm-example", label: "questmaster", configFiles: ["/tmp/config.conf"], live: true, createdUnix: 1)
        controller.rememberRoutes([legacy])
        controller.switchTerminal(to: legacy.sessionID)
        try expect(host.labels == ["default"] && routes.pending.count == 1, "cached route should attach before refresh completes")
        routes.pending[0](.failure(ServeClientError.connect("daemon restarting")))
        try pumpOneMainRunLoopTurn()
        controller.switchTerminal(to: legacy.sessionID)
        try expect(host.labels == ["default", "default"] && routes.pending.count == 2, "refresh failure should retain the cached route")
        routes.pending[1](.success([named]))
        try pumpOneMainRunLoopTurn()
        controller.switchTerminal(to: named.sessionID)
        try expect(host.labels == ["default", "default", "questmaster"], "route refresh should replace the cached label")
    }

    private static func testContinuedSessionFetchesMovedRouteBeforeAttach() throws {
        let legacy = try TmuxRoute(sessionID: "qm-example", label: "default", configFiles: [], live: false, createdUnix: 1)
        let named = try TmuxRoute(sessionID: legacy.sessionID, label: "questmaster", configFiles: ["/tmp/example/config.conf"], live: true, createdUnix: 1)
        let routes = RouteTestClient()
        routes.reply = .success([named])
        let host = RouteTestHost()
        let controller = makeRouteTestController(routes: routes, host: host)
        controller.rememberRoutes([legacy])
        controller.markSessionReappeared(legacy.sessionID)

        var completed: Bool?
        controller.switchTerminal(to: legacy.sessionID) { completed = $0 }
        try expect(waitUntil { completed != nil }, "continued session attach should complete")
        try expect(host.labels == ["questmaster"] && completed == true && controller.activeTmuxSession == legacy.sessionID,
                   "Continue should attach only to the daemon's current route")
    }

    private static func testFailedCachedAttachRetriesRefreshedRoute() throws {
        let legacy = try TmuxRoute(sessionID: "qm-example", label: "default", configFiles: [], live: true, createdUnix: 1)
        let named = try TmuxRoute(sessionID: legacy.sessionID, label: "questmaster", configFiles: ["/tmp/example/config.conf"], live: true, createdUnix: 1)
        let routes = RouteTestClient()
        let host = RouteTestHost()
        let controller = makeRouteTestController(routes: routes, host: host)
        controller.rememberRoutes([legacy])

        var completed: Bool?
        controller.switchTerminal(to: legacy.sessionID) { completed = $0 }
        try expect(host.labels.first == "default" && routes.pending.count == 1,
                   "cached route should start while refresh is pending")
        try expect(completed == nil && host.labels == ["default"],
                   "a failed cached attach should wait for its route refresh")
        routes.pending[0](.success([named]))
        try expect(waitUntil { completed != nil }, "refreshed route should finish the attach")
        try expect(host.labels == ["default", "questmaster"] && completed == true && controller.attachedRoute == named,
                   "a failed cached attach should retry once on the daemon's changed route")
    }

    private static func testFailedCachedAttachRetriesRouteRefreshedFirst() throws {
        let legacy = try TmuxRoute(sessionID: "qm-example", label: "default", configFiles: [], live: true, createdUnix: 1)
        let named = try TmuxRoute(sessionID: legacy.sessionID, label: "questmaster", configFiles: ["/tmp/example/config.conf"], live: true, createdUnix: 1)
        let routes = RouteTestClient()
        let host = RouteTestHost()
        host.deferDefaultFailure = true
        let controller = makeRouteTestController(routes: routes, host: host)
        controller.rememberRoutes([legacy])

        var completed: Bool?
        controller.switchTerminal(to: legacy.sessionID) { completed = $0 }
        try expect(routes.pending.count == 1, "cached route should refresh during attach")
        routes.pending[0](.success([named]))
        try pumpOneMainRunLoopTurn()
        try expect(completed == nil && host.labels == ["default"], "a refreshed route should wait for the first attach result")
        host.finishDefaultFailure?()
        try expect(host.labels == ["default", "questmaster"] && completed == true && controller.attachedRoute == named,
                   "the changed daemon route should also be used when refresh completes before attach failure")
    }

    private final class RouteTestClient: ServeTmuxRouting {
        var reply: Result<[TmuxRoute], Error>?
        var pending: [(Result<[TmuxRoute], Error>) -> Void] = []

        func fetchTmuxRoutes(sessionIDs: [String], live: Bool, completion: @escaping (Result<[TmuxRoute], Error>) -> Void) {
            if let reply { completion(reply) } else { pending.append(completion) }
        }
    }

    private final class RouteTestHost: TerminalPaneHosting {
        let view = NSView()
        var tmuxSessionID: String? { nil }
        var onFocusRequested: (() -> Void)?
        var onDetach: (() -> Void)?
        var cellMetrics: TerminalCellMetrics { .unavailable }
        var onCellMetricsChanged: (() -> Void)?
        var labels: [String] = []
        var deferDefaultFailure = false
        var finishDefaultFailure: (() -> Void)?

        func start() {}
        func stop() {}
        func focus(in window: NSWindow?) {}
        func connect(to config: TerminalLaunchConfig, completion: @escaping (Result<String?, Error>) -> Void) {
            labels.append(config.route?.label ?? "local")
            if config.route?.label == "default" {
                let fail = { completion(.failure(TmuxRouteError.missingSession(config.tmuxSession ?? ""))) }
                if deferDefaultFailure { finishDefaultFailure = fail } else { fail() }
            } else {
                completion(.success(config.tmuxSession))
            }
        }
    }

    private static func makeRouteTestController(routes: ServeTmuxRouting, host: TerminalPaneHosting) -> TerminalSessionController {
        let config = LaunchConfiguration(
            daemonSocketOverride: nil, startDaemon: false, tmuxSession: nil,
            disableTmux: false, workingDirectory: "/tmp",
            backend: AppBackend(stateRoot: "/tmp/example-state", executablePath: "", source: .unresolved,
                                workingDirectory: "/tmp", devWorktree: nil)
        )
        let controller = TerminalSessionController(
            config: config, runtimeStore: RuntimeStore(sourceLabel: "test"), routeClient: routes,
            terminalShell: { nil }, updateWindowTitle: { _ in }, focusTerminal: {}, render: {},
            showMutationFailure: { _, _ in }, showMutationError: { _, _ in },
            showTerminalEngineFailure: { _ in }, onFocusRequested: {}
        )
        controller.installPlaceholder(host)
        return controller
    }

    private static func testStartupChoiceAcrossServers() throws {
        let legacy = try TmuxRoute(sessionID: "qm-old", label: "default", configFiles: [], live: true, createdUnix: 100)
        let named = try TmuxRoute(sessionID: "qm-new", label: "questmaster", configFiles: ["/tmp/config.conf"], live: true, createdUnix: 300)
        let stopped = try TmuxRoute(sessionID: "qm-stopped", label: "default", configFiles: [], live: false, createdUnix: 500)
        try expect(TmuxRoute.startupChoice(preferred: "qm-old", routes: [legacy, named, stopped]) == legacy, "live preferred session should win across servers")
        try expect(TmuxRoute.startupChoice(preferred: "qm-stopped", routes: [legacy, named, stopped]) == named, "newest live route should win")
    }

    private static func testEditorWindowUsesAttachedRoute() throws {
        let attached = try TmuxRoute(sessionID: "qm-attached", label: "questmaster", configFiles: ["/tmp/config.conf"], live: true, createdUnix: 1)
        let args = TerminalTmuxClientProcess.editorWindowArguments(route: attached, path: "/tmp/a.md", shell: "/bin/zsh")
        try expect(Array(args.prefix(4)) == ["-L", "questmaster", "-f", "/tmp/config.conf"], "Markdown editor should use attached route")
        try expect(args.contains("=qm-attached"), "Markdown editor should target attached session")
    }

    private static func testNavigationTogglesKeepFocusAndHideToTerminal() throws {
        var state = AppNavigationState(trackerVisible: false, dockVisible: false)
        try expect(state.toggleTracker() == .unchanged, "showing tracker should not move focus")
        try expect(state.trackerVisible, "tracker should show")
        try expect(state.focusedRegion == .terminal, "showing tracker should leave the terminal focused")

        state = AppNavigationState(focusedRegion: .dock, trackerVisible: false, dockVisible: true)
        try expect(state.toggleTracker() == .unchanged, "showing tracker from dock should not move focus")
        try expect(state.trackerVisible, "tracker should show while dock is focused")
        try expect(state.focusedRegion == .dock, "showing tracker should leave the dock focused")

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
        func pressed(_ action: Keymap.Action, _ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> Bool {
            Keymap.matches(try keyEvent(characters, keyCode: keyCode, modifierFlags: flags).keymapPress, action)
        }
        try expect(try pressed(.moveUp, "k", 40), "list k should move up")
        try expect(try pressed(.open, "\r", 36), "list Enter should open selection")
        try expect(!(try pressed(.open, "\u{1c}", 124)), "list right arrow should not open selection")
        try expect(!(try pressed(.open, "l", 37)), "list l should not open selection")
        try expect(try pressed(.delete, "d", 2), "list delete should be d")
        try expect(!(try pressed(.delete, "x", 7)), "x should not delete list items")
        try expect(Keymap.Command.deleteFocusedSession.keyEquivalent == "d", "focused session delete should use d")
        try expect(Keymap.Command.deleteFocusedSession.modifiers == [.command, .shift], "focused session delete should use command-shift-d")
        try expect(try pressed(.back, "\u{1c}", 123), "viewer back should include left arrow")
        try expect(try pressed(.back, "h", 4), "viewer h should go back")
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

    /// The page loads only behind the remote-content blocker. When the blocker doesn't compile, the viewer shows its
    /// blocked pane and loads nothing: the page view is taken down, and the page it held never got a URL.
    private static func testArtifactViewerLoadsNothingWhenTheBlockerFailsToCompile() throws {
        let page = try temporaryArtifactPage()
        defer { try? FileManager.default.removeItem(atPath: page.path) }
        let compiler = DeferredRuleListCompiler()
        let window = HeadlessWindow(size: artifactViewerSize)
        let host = NSHostingView(rootView: artifactViewer(page, compiler: compiler))
        host.frame = NSRect(origin: .zero, size: artifactViewerSize)
        window.contentView = host
        window.show()
        defer { window.close() }

        // The compile is held, so the page view is in the tree while the blocker is still pending.
        let webView = try pageView(in: host)
        try expect(waitUntil { compiler.attempts == 1 }, "the viewer should ask for the blocker once")
        compiler.failCompile()
        try expect(
            waitUntil { !subviews(of: host).contains { $0 is WKWebView } },
            "the blocked pane should replace the page view when the blocker fails"
        )
        try pumpOneMainRunLoopTurn()
        try expect(webView.url == nil && !webView.isLoading, "no page should load when the blocker fails, got \(String(describing: webView.url))")
        let bitmap = try snapshot(host, size: artifactViewerSize, scale: 1)
        try expect(
            inkEdges(bitmap, scale: 1, columns: 0..<Int(artifactViewerSize.width), rows: 0..<Int(artifactViewerSize.height), over: AppPalette.artifactViewerBackground) != nil,
            "the blocked pane should draw its message"
        )
    }

    /// The control for the test above: with a blocker that compiles, the same viewer does load the page, so the page
    /// staying unloaded there means the blocker held it.
    private static func testArtifactViewerLoadsThePageOnceTheBlockerCompiles() throws {
        let page = try temporaryArtifactPage()
        defer { try? FileManager.default.removeItem(atPath: page.path) }
        let window = HeadlessWindow(size: artifactViewerSize)
        let host = NSHostingView(rootView: artifactViewer(page, compiler: WebKitRuleListCompiler()))
        host.frame = NSRect(origin: .zero, size: artifactViewerSize)
        window.contentView = host
        window.show()
        defer { window.close() }

        let webView = try pageView(in: host)
        try expect(waitUntil { webView.url != nil }, "the page should load once the blocker compiles")
    }

    /// The page view the viewer builds for an HTML artifact, once SwiftUI has laid the hosted viewer out.
    private static func pageView(in host: NSView) throws -> WKWebView {
        guard waitUntil({ subviews(of: host).contains { $0 is WKWebView } }),
              let view = subviews(of: host).compactMap({ $0 as? WKWebView }).first else {
            throw TestFailure("the viewer should build the page view for an HTML artifact")
        }
        return view
    }

    private static let artifactViewerSize = CGSize(width: 320, height: 240)

    private static func artifactViewer(_ page: ArtifactReference, compiler: any ArtifactRuleListCompiling) -> some View {
        ArtifactViewerPane(
            displayState: .viewing(page),
            reloadNonce: 0,
            onOpenExternal: { _ in },
            ruleListCompiler: compiler
        )
        .frame(width: artifactViewerSize.width, height: artifactViewerSize.height)
    }

    /// A real page in the temp directory, so a load that slips past the blocker would succeed.
    private static func temporaryArtifactPage() throws -> ArtifactReference {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("questmaster-blocker-probe-\(UUID().uuidString).html")
        try Data("<!doctype html><meta charset=\"utf-8\"><title>Probe</title><p>Probe</p>".utf8).write(to: url)
        return ArtifactReference(kind: "html", path: url.path, label: "Probe", sessionID: "qm-probe", addedAt: "")
    }

    private static func testArtifactExternalOpenRouting() throws {
        try expect(ArtifactExternalRoute.classify(path: "/tmp/report.MD") == .editor, "Markdown should use the editor")
        try expect(ArtifactExternalRoute.classify(path: "/tmp/report.html") == .browser, "HTML should use the browser")
        try expect(ArtifactExternalRoute.classify(path: "/tmp/diagram.PNG") == .preview, "images should use Preview")
        try expect(ArtifactExternalRoute.classify(path: "/tmp/data.csv") == .system, "other files should use their default app")
        let missing = ArtifactReference(
            kind: "markdown",
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.md").path,
            label: "Missing",
            addedAt: ""
        )
        do {
            try ArtifactExternalOpener.open(artifact: missing, attachedRoute: nil, tmuxPath: "/usr/bin/tmux", environment: [:])
            throw TestFailure("missing artifact should fail before launching an app")
        } catch ArtifactExternalOpenError.missingFile {
            // Expected.
        }
    }

    private static func testArtifactEditorWindowKeepsPathSeparate() throws {
        let path = "/tmp/report ' with spaces; $(touch danger).md"
        let route = try TmuxRoute(sessionID: "qm-a", label: "default", configFiles: [], live: true, createdUnix: 1)
        let args = TerminalTmuxClientProcess.editorWindowArguments(route: route, path: path, shell: "/bin/zsh")
        try expect(Array(args.prefix(7)) == ["-L", "default", "new-window", "-t", "=qm-a", "-n", "Artifact"], "editor should open a new tmux window")
        try expect(args[8] == "/tmp", "editor window should start beside the artifact")
        try expect(args[9].contains("artifact_path=$1"), "editor script should read the path as an argument")
        try expect(args[9].hasSuffix("'/tmp/report '\\'' with spaces; $(touch danger).md'"), "path should be shell quoted as one positional argument")
        try expect(args[9].contains("eval \"set -- $EDITOR\""), "editor command should allow arguments")
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

    /// The Watcher panel's keys: j/k and the arrows move the cursor, Return opens the row's page, y copies its URL
    /// and r asks the daemon to refresh; a click picks and opens; modified keys and others pass through.
    private static func testWatcherDockKeysMoveOpenCopyAndRefresh() throws {
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

        let pane = WatcherDockPane(store: store)
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

    /// The skeletons (the terminal's veil, the tracker's ghost plates, the Settings pickers' ghosts) breathe in one way: a Core
    /// Animation fade of the layer their content was drawn on, once every `SkeletonMotion.period`, for good, only while in a
    /// window, and held still at the resting opacity under Reduce Motion. SwiftUI never animates them, so nothing redraws.
    private static func testSkeletonsBreatheByCoreAnimationOnlyInAWindowAndHoldStillUnderReduceMotion() throws {
        let size = CGSize(width: 520, height: 300)
        let window = HeadlessWindow(size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container

        let pulse = SkeletonPulseView(rootView: Color.clear)
        pulse.frame = container.bounds
        pulse.configure(rootView: Color.clear, from: 0.6, to: 0.7, reduceMotion: false)
        try expect(pulse.pulseAnimation == nil, "a skeleton outside a window should not breathe")
        container.addSubview(pulse)
        guard let breath = pulse.pulseAnimation else {
            throw TestFailure("a skeleton in a window should breathe")
        }
        try expect(
            breath.keyPath == "opacity" && breath.fromValue as? Double == 0.6 && breath.toValue as? Double == 0.7
                && breath.duration == SkeletonMotion.period && breath.autoreverses && breath.repeatCount == .infinity,
            "it fades between its two opacities, once every \(SkeletonMotion.period)s, for good"
        )
        try expect(breath.timingFunction === Motion.breathingTimingFunction, "and on the breathing easing, the token")
        pulse.configure(rootView: Color.clear, from: 0.6, to: 0.7, reduceMotion: true)
        try expect(pulse.pulseAnimation == nil && pulse.layer?.opacity == 0.7, "Reduce Motion holds it still at the resting opacity")
        pulse.configure(rootView: Color.clear, from: 0.6, to: 0.7, reduceMotion: false)
        try expect(pulse.pulseAnimation != nil, "and it breathes again when the setting goes")
        pulse.removeFromSuperview()
        try expect(pulse.pulseAnimation == nil, "a skeleton that leaves its window stops")

        /// The breaths running anywhere under `view`.
        func breaths(in view: NSView) -> [CABasicAnimation] {
            let own = (view.layer?.animation(forKey: SkeletonMotion.animationKey) as? CABasicAnimation).map { [$0] } ?? []
            return view.subviews.reduce(own) { $0 + breaths(in: $1) }
        }
        func hosted<V: View>(_ root: V, shouldBreathe: Bool) throws -> [CABasicAnimation] {
            let view = NSHostingView(rootView: root.frame(width: size.width, height: size.height).background(AppPalette.window.swiftUI))
            view.frame = NSRect(origin: .zero, size: size)
            let host = HeadlessWindow(size: size, scale: 1)
            host.contentView = view
            host.show()
            defer { host.close() }
            try expect(waitUntil {
                view.window === host && view.layer != nil && (!shouldBreathe || !breaths(in: view).isEmpty)
            }, "the skeleton view should mount and start its expected motion")
            return breaths(in: view)
        }
        func tracker(_ connection: ConnectionState) -> some View {
            let store = RuntimeStore(sourceLabel: "test")
            store.apply(RuntimeUpdate(connection: connection))
            return TrackerRootView(store: store, newSessionPresenter: NewSessionSheetPresenter(), destructiveConfirmationPresenter: DestructiveConfirmationPresenter())
        }
        let settings = SettingsSheetView(
            presentation: SettingsSheetPresentation(
                mutationClient: StubMutationClient(result: .success(ServeMutationAck(data: nil))),
                modelClient: StubModelClient(deferCompletions: true),
                effortClient: StubReasoningEffortClient(),
                runtime: RuntimeStore(sourceLabel: "test")
            ),
            dismiss: {}
        )

        // Reduce Motion is read where every animation reads it (`Motion.reducesMotion`), so the runner's setting rules whatever
        // the machine says; a CI runner has it on, and a skeleton that asked SwiftUI's environment instead never breathed there.
        // Forced on here, the real skeletons must hold still, which only a view reading the token can do on a machine without it.
        Motion.reducesMotion = { true }
        defer { Motion.reducesMotion = { false } }
        try expect(try hosted(TerminalAttachSkeleton(), shouldBreathe: false).isEmpty, "the terminal's veil holds still under Reduce Motion")
        try expect(try hosted(tracker(.connecting), shouldBreathe: false).isEmpty, "the tracker's ghost plates hold still under Reduce Motion")
        try expect(try hosted(settings, shouldBreathe: false).isEmpty, "the Settings pickers hold still under Reduce Motion")
        Motion.reducesMotion = { false }

        let veil = try hosted(TerminalAttachSkeleton(), shouldBreathe: true)
        try expect(veil.count == 1 && veil[0].duration == SkeletonMotion.period, "the terminal's veil should be one breath, got \(veil.count)")
        let ghosts = try hosted(tracker(.connecting), shouldBreathe: true)
        try expect(ghosts.count == 1 && ghosts[0].duration == SkeletonMotion.period, "the tracker's ghost plates should be one breath, got \(ghosts.count)")
        try expect(try hosted(tracker(.connected), shouldBreathe: false).isEmpty, "a tracker with a backend shows no skeleton and nothing breathes")
        let pickers = try hosted(settings, shouldBreathe: true)
        try expect(!pickers.isEmpty && pickers.allSatisfy { $0.duration == SkeletonMotion.period }, "the Settings pickers waiting for options should breathe, got \(pickers.count)")
    }

    /// An empty panel draws the one icon and nothing else, centred in the section its list would fill: the whole panel, or what is
    /// left under the artifact list's tabs. Measured as the ink on the panel's fill, so it holds for whatever the icon is.
    private static func testEveryEmptyPanelDrawsTheOneIconCentredInItsSection() throws {
        func ink<V: View>(_ root: V, size: CGSize, below top: Int = 0, over fill: NSColor = AppPalette.panel) throws -> CGRect? {
            let view = NSHostingView(rootView: root.frame(width: size.width, height: size.height).background(fill.swiftUI))
            view.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: size, scale: 1)
            window.contentView = view
            window.show()
            defer { window.close() }
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try pumpOneMainRunLoopTurn()
            let bitmap = try snapshot(view, size: size, scale: 1)
            guard let base = fill.usingColorSpace(.deviceRGB) else {
                throw TestFailure("could not read the panel fill")
            }
            var box: CGRect?
            for y in top..<Int(size.height) {
                for x in 0..<Int(size.width) {
                    guard let pixel = bitmap.colorAt(x: x, y: y),
                          abs(pixel.redComponent - base.redComponent) + abs(pixel.greenComponent - base.greenComponent)
                            + abs(pixel.blueComponent - base.blueComponent) > 0.05 else {
                        continue
                    }
                    box = (box ?? CGRect(x: x, y: y, width: 0, height: 0)).union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
            return box
        }
        func expectCentred(_ box: CGRect?, in section: CGRect, _ name: String) throws {
            guard let box else {
                throw TestFailure("\(name) should draw the icon")
            }
            try expect(
                abs(box.midX - section.midX) <= 1 && abs(box.midY - section.midY) <= 1,
                "\(name)'s icon should be centred in its section \(section), got \(box)"
            )
            try expect(box.width <= Token.Size.emptyIcon && box.height <= Token.Size.emptyIcon, "\(name) should draw one icon in a \(Token.Size.emptyIcon)pt box, got \(box)")
        }

        let single = CGSize(width: 300, height: 200)
        try expectCentred(try ink(EmptyState(), size: single), in: CGRect(origin: .zero, size: single), "the shared empty state")

        let terminal = CGSize(width: 600, height: 400)
        try expectCentred(
            try ink(TerminalEndedOverlay(), size: terminal, over: AppPalette.terminal),
            in: CGRect(origin: .zero, size: terminal),
            "the ended terminal"
        )

        let watcher = CGSize(width: DockWidthPreference.panelWidth, height: 260)
        try expectCentred(
            try ink(WatcherList(rows: [], cursorKey: nil, isUnwatched: true, readNotice: nil, areaFocused: true, onOpenRow: { _ in }), size: watcher),
            in: CGRect(origin: .zero, size: watcher),
            "Watcher"
        )

        let chat = CGSize(width: DockWidthPreference.panelWidth, height: 400)
        let master = [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")]
        let pending = WorkerChatStore()
        let firstRead = pending.sync(selectedSessionID: "m", sessions: master, isVisible: true)
        try expect(try ink(WorkerChatDockView(store: pending, areaFocused: true), size: chat) == nil, "a worker chat whose first read is pending should stay blank")
        pending.fail(firstRead!)
        try expect(try ink(WorkerChatDockView(store: pending, areaFocused: true), size: chat) == nil, "and so should one whose first read failed")
        let retry = pending.sync(selectedSessionID: "m", sessions: master, isVisible: true)
        _ = pending.receive(WorkerFeedPayload(), for: retry!)
        try expectCentred(try ink(WorkerChatDockView(store: pending, areaFocused: true), size: chat), in: CGRect(origin: .zero, size: chat), "the worker chat once a read came back empty")
        try expect(try ink(WorkerChatDockView(store: WorkerChatStore(), areaFocused: true), size: chat) == nil, "an unattached worker chat should stay blank")

        func artifacts(_ route: ArtifactDockRoute) -> some View {
            var model = ArtifactDockModel.empty
            model.route = route
            model.displayState = .empty(sessionID: "s")
            return ArtifactDockView(
                model: model,
                onSelectArtifact: { _ in }, onToggleArtifact: { _ in }, onSetScope: { _ in }, onSetFilterQuery: { _ in },
                onRemoveFilterToken: { _ in }, onSelectFilterSuggestion: { _ in }, onFilterCommand: { _ in false }, onFilterEndEditing: {},
                onOpenExternal: { _ in }, areaFocused: true
            )
        }
        let dock = CGSize(width: DockWidthPreference.panelWidth, height: 400)
        try expectCentred(try ink(artifacts(.viewer), size: dock), in: CGRect(origin: .zero, size: dock), "the artifact viewer")
        let listTop = Space.section + ControlHeight.compact + Space.section
        try expectCentred(
            try ink(artifacts(.list), size: dock, below: Int(listTop)),
            in: CGRect(x: 0, y: listTop, width: dock.width, height: dock.height - listTop),
            "the artifact list under its tabs"
        )
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

    /// The Watcher title bar shows the spinner beside its title exactly while the pull request store refreshes
    /// (`r` until the daemon's reply and one turn), and the other docks never do. It reads the ring's presence, not its
    /// animation: a hosted ring turns or holds still by the host's Reduce Motion setting (`SpinnerRingView` reads the
    /// environment's), and CI's macOS runner reduces motion where a desk doesn't, so the turn is tested on the view
    /// itself (`testRefreshSpinnerIsTheTrackersSpinnerAndTurnsOnlyInAWindow`).
    private static func testWatcherTitleBarShowsTheSpinnerWhileTheStoreRefreshes() throws {
        let store = PullRequestStore()
        let session = TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", role: "master", pullRequestsRev: "1")
        _ = store.sync(selectedSessionID: "qm-a", sessions: [session], isVisible: true)
        let window = HeadlessWindow(size: CGSize(width: 480, height: 300))
        let top = DockShellView(body: NSView(), model: DockChromeModel(topBar: .watcher, isRefreshing: { store.isRefreshing }))
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
        try waitForMainQueue("the spinner to appear") { spinner(in: top) != nil }
        try expect(spinner(in: bottom) == nil, "the bottom panel's bar never shows it")

        store.finishRefresh(request, failed: false, now: now.addingTimeInterval(PullRequestStore.refreshMinimumShown + 1))
        try waitForMainQueue("the spinner to go") { spinner(in: top) == nil }
    }

    /// The column puts Watcher on top at 300, the bottom panel under it, 20 apart; a panel alone fills the column and
    /// a hidden one leaves the view hidden.
    private static func testDockColumnLaysOutItsPanels() throws {
        let top = DockShellView(body: NSView(), model: DockChromeModel(topBar: .watcher))
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
        try expect(top.frame == NSRect(x: 0, y: 560, width: 480, height: 300), "Watcher sits at the column's top, 300 tall, got \(top.frame)")
        try expect(bottom.frame == NSRect(x: 0, y: 0, width: 480, height: 540), "the bottom panel takes what's left under a 20 gap, got \(bottom.frame)")

        _ = laidOut(DockPanels(top: true))
        try expect(!top.isHidden && bottom.isHidden, "Watcher alone leaves the bottom panel hidden")
        try expect(top.frame == NSRect(x: 0, y: 0, width: 480, height: 860), "Watcher alone fills the dock, got \(top.frame)")

        _ = laidOut(DockPanels(bottom: true))
        try expect(top.isHidden && !bottom.isHidden, "the bottom panel alone leaves Watcher hidden")
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
            toggleWatcherDock: .anywhere { ran.append("⇧⌘R") }
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

        // Out of the dock's scope (the terminal or tracker focused, or a dock with one panel) the dock's chords
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
            let top = DockShellView(body: NSView(), model: DockChromeModel(topBar: .watcher))
            let bottom = DockShellView(body: NSView())
            let column = DockColumnView(top: top, bottom: bottom)
            column.frame = NSRect(x: 500, y: 0, width: 480, height: 860)
            content.addSubview(column)
            window.contentView = content
            window.show()
            return (column, top, bottom, window)
        }
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
        try expect(waitUntil { column.isTransitioning && top.alphaValue > 0 && top.alphaValue < 1 }, "the appearing panel should reach an intermediate state")
        try expect(waitUntil { !column.isTransitioning }, "the dock's panel transition should finish")
        try expect(top.alphaValue == 1 && top.frame == NSRect(x: 0, y: 560, width: 480, height: 300), "Watcher ends at its slot, got \(top.frame)")
        try expect(bottom.alphaValue == 1 && bottom.frame == NSRect(x: 0, y: 0, width: 480, height: 540), "the bottom panel ends shrunk under it, got \(bottom.frame)")

        column.setPanels(DockPanels(bottom: true), animated: true)
        try expect(column.isTransitioning && !top.isHidden, "a panel going away stays up while it fades")
        try expect(waitUntil { !column.isTransitioning && top.isHidden }, "the closing panel should finish fading out")
        try expect(bottom.frame == NSRect(x: 0, y: 0, width: 480, height: 860) && bottom.alphaValue == 1, "and the bottom panel fills the dock again, got \(bottom.frame)")

        // A new change mid-transition settles the running one first.
        column.setPanels(DockPanels(top: true, bottom: true), animated: true)
        try expect(waitUntil { column.isTransitioning && top.alphaValue > 0 && top.alphaValue < 1 }, "the dock should be mid-transition before the next change")
        column.setPanels(DockPanels(top: true), animated: true)
        try expect(column.isTransitioning, "the interrupting change starts its own transition")
        try expect(waitUntil { !column.isTransitioning }, "the interrupted dock transition should settle on the latest panel")
        try expect(bottom.isHidden && top.frame == NSRect(x: 0, y: 0, width: 480, height: 860) && top.alphaValue == 1, "and the dock ends on its latest panels, got \(top.frame)")

        let (still, stillTop, stillBottom, stillWindow) = makeColumn()
        defer { stillWindow.close() }
        Motion.reducesMotion = { true }
        defer { Motion.reducesMotion = { false } }
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
        let pane = WatcherDockPane(store: PullRequestStore())
        let bottomPane = SwiftUIDockPane(
            store: RuntimeStore(sourceLabel: "test"),
            workerChatStore: WorkerChatStore(),
            newQuestPresenter: NewQuestSheetPresenter(),
            settingsPresenter: SettingsSheetPresenter()
        )
        let top = DockShellView(body: pane, model: DockChromeModel(topBar: .watcher))
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
            actionBar: { nil },
            trackerHosting: { nil },
            dockView: { bottomPane },
            watcherPane: { pane },
            terminalHost: { nil },
            modalHost: { nil },
            updateDockTabs: {}
        )
        window.show(key: true)
        defer { window.close() }

        coordinator.focusDockPanel(.top)
        try expect(window.firstResponder === pane, "the top panel's pane should take the keys")
        try expect(top.isFocused && !bottom.isFocused, "only the top panel's frame should lift")
        try expect(pane.hasFocusedLook && !bottomPane.isFocused, "Watcher draws its cursor, and the bottom panel's content its focused look, only for the panel with the keys")
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
        var keys = ListKeyResolver()
        try expect(dockKey(try keyEvent("j", keyCode: 38), &keys, model, snapshot), "j should select the next artifact")
        try expect(coordinator.state.selectedArtifactID == second.id, "artifact selection should persist before the next render")

        _ = model.apply(
            coordinator.state,
            snapshot: snapshot,
            preferredArtifactSessionID: "qm-a"
        )
        try expect(model.artifactModel.selectedArtifactID == second.id, "render should retain the selected artifact")
    }

    private static func testArtifactExternalOpenUsesCurrentListAndViewerArtifact() throws {
        let artifact = ArtifactReference(kind: "markdown", path: "/tmp/report.md", label: "Report", sessionID: "qm-a", addedAt: "", id: "art-report")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [TrackerRepo(id: "repo-a", name: "Alpha", sessions: [
            TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", artifacts: [artifact]),
        ])])
        let model = DockPaneModel()
        var opened: [ArtifactReference] = []
        model.onOpenArtifactExternal = { opened.append($0) }
        var keys = ListKeyResolver()
        _ = model.apply(DockState(dockContent: .artifactList, selectedArtifactID: artifact.id), snapshot: snapshot, preferredArtifactSessionID: "qm-a")
        try expect(dockKey(try keyEvent("o", keyCode: 31), &keys, model, snapshot), "list o should be handled")
        _ = model.apply(DockState(dockContent: .artifactViewer, selectedArtifactID: artifact.id), snapshot: snapshot, preferredArtifactSessionID: "qm-a")
        try expect(dockKey(try keyEvent("o", keyCode: 31), &keys, model, snapshot, in: []), "viewer o should be handled")
        try expect(opened == [artifact, artifact], "list and viewer should open the same artifact externally")
    }

    private static func testKeymapPressReadsEventsAsTheKeymapDoes() throws {
        try expect(try keyEvent("g", keyCode: 5).keymapPress == Keymap.KeyPress(keyCode: 5, character: "g"), "a plain g should press g")
        try expect(try keyEvent("G", keyCode: 5, modifierFlags: [.shift]).keymapPress == Keymap.KeyPress(keyCode: 5, character: "G"), "shift-g should press G, with shift folded into the character")
        try expect(try keyEvent("\r", keyCode: 36, modifierFlags: [.shift]).keymapPress == Keymap.KeyPress(keyCode: 36, character: "\r", modifiers: [.shift]), "shift-Return keeps shift, since it types no character")
        try expect(try keyEvent("j", keyCode: 38, modifierFlags: [.control]).keymapPress == Keymap.KeyPress(keyCode: 38, character: "j", modifiers: [.control]), "control-j keeps control")
    }

    /// Caps Lock is transparent: a letter's case comes from Shift alone, so caps+j is j, caps+shift+g is G, and the
    /// keys behave as they do without Caps Lock. The event's own case is not trusted: the OS gives the reverse with Shift.
    private static func testKeymapPressIgnoresCapsLock() throws {
        func press(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> Keymap.KeyPress {
            try keyEvent(characters, keyCode: keyCode, modifierFlags: flags).keymapPress
        }
        try expect(try press("J", 38, [.capsLock]) == Keymap.KeyPress(keyCode: 38, character: "j"), "caps-lock j should press j")
        try expect(try press("g", 5, [.capsLock, .shift]) == Keymap.KeyPress(keyCode: 5, character: "G"), "caps-lock with shift should press the capital G")
        try expect(try press("G", 5, [.capsLock]) == Keymap.KeyPress(keyCode: 5, character: "g"), "caps-lock alone should press the lowercase g")
        try expect(try press("1", 18, [.capsLock]) == Keymap.KeyPress(keyCode: 18, character: "1"), "caps-lock leaves digits alone")
        try expect(Keymap.matches(try press("D", 2, [.capsLock]), .delete), "caps-lock d should delete, as d does")
        try expect(Keymap.matches(try press("E", 14, [.capsLock]), .edit), "caps-lock e should edit the session, not the repo")
        try expect(!Keymap.matches(try press("E", 14, [.capsLock]), .editRepo), "caps-lock e must not edit the repo")
        try expect(Keymap.matches(try press("C", 8, [.capsLock]), .toggleWorkersCollapsed), "caps-lock c should collapse the workers, as c does")
        try expect(Keymap.matches(try press("g", 5, [.capsLock, .shift]), .jumpToBottom), "caps-lock+shift g should jump to bottom")
        try expect(Keymap.matches(try press("G", 5, [.capsLock]), .jumpToTop), "caps-lock g should arm the gg chord")
        try expect(Keymap.matches(try press("h", 4, [.command, .shift, .capsLock]), .focusLeft), "⇧⌘H with caps-lock should still focus left")
    }

    private static func testGChordShortcutIgnoresCapsLock() throws {
        func pressed(_ action: Keymap.Action, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> Bool {
            Keymap.matches(try keyEvent(characters, keyCode: 5, modifierFlags: flags).keymapPress, action)
        }
        try expect(try pressed(.jumpToTop, "g"), "plain g should arm the chord")
        try expect(!(try pressed(.jumpToBottom, "g")), "plain g should not jump to bottom")

        try expect(try pressed(.jumpToBottom, "G", [.shift]), "shift-G should jump to bottom")
        try expect(!(try pressed(.jumpToTop, "G", [.shift])), "shift-G should not arm the chord")

        // Caps Lock is transparent: caps-lock g is g, so it arms the chord, as it does without Caps Lock.
        try expect(try pressed(.jumpToTop, "G", [.capsLock]), "caps-lock g should arm the chord")
        try expect(!(try pressed(.jumpToBottom, "G", [.capsLock])), "caps-lock g should not jump to bottom")

        // Caps Lock with Shift is G, the same as Shift alone.
        try expect(try pressed(.jumpToBottom, "g", [.capsLock, .shift]), "caps-lock+shift g should jump to bottom")
        try expect(!(try pressed(.jumpToTop, "g", [.capsLock, .shift])), "caps-lock+shift g should not arm the chord")

        try expect(!(try pressed(.jumpToTop, "g", [.command])), "command-g should not arm the chord")
        try expect(!(try pressed(.jumpToBottom, "G", [.command, .shift])), "command-shift-G should not jump to bottom")
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

        var keys = ListKeyResolver()
        let shiftG = try keyEvent("G", keyCode: 5, modifierFlags: [.shift])
        try expect(dockKey(shiftG, &keys, model, snapshot), "G should be handled")
        try expect(model.artifactModel.selectedArtifactID == third.id, "G should select the last artifact")
        let nonceAfterFirstJump = model.artifactModel.scrollNonce

        try expect(dockKey(shiftG, &keys, model, snapshot), "G should still be handled when already at the last artifact")
        try expect(model.artifactModel.scrollNonce != nonceAfterFirstJump, "repeating G at the edge should still force a rescroll")

        let g = try keyEvent("g", keyCode: 5)
        try expect(dockKey(g, &keys, model, snapshot), "first g should arm the gg chord")
        try expect(dockKey(g, &keys, model, snapshot), "second g within the window should jump to the first artifact")
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
        var afterGKeys = ListKeyResolver()
        let last = afterG.artifactModel.artifacts.last?.id
        try expect(dockKey(g, &afterGKeys, afterG, snapshot), "g should arm the chord")
        try expect(dockKey(shiftG, &afterGKeys, afterG, snapshot), "G should jump to the last artifact, not continue the chord")
        try expect(afterG.artifactModel.selectedArtifactID == last, "G should select the last artifact")
        try expect(dockKey(g, &afterGKeys, afterG, snapshot), "g right after G should re-arm rather than resolve")
        try expect(afterG.artifactModel.selectedArtifactID == last, "a freshly re-armed g alone should not move the selection")

        let afterOtherKey = listModel()
        var otherKeys = ListKeyResolver()
        let selected = afterOtherKey.artifactModel.selectedArtifactID
        try expect(dockKey(g, &otherKeys, afterOtherKey, snapshot), "g should arm the chord")
        _ = dockKey(try keyEvent("x", keyCode: 7), &otherKeys, afterOtherKey, snapshot)
        try expect(dockKey(g, &otherKeys, afterOtherKey, snapshot), "g after an unrelated key should re-arm rather than resolve")
        try expect(afterOtherKey.artifactModel.selectedArtifactID == selected, "a freshly re-armed g alone should not move the selection")
    }

    /// `[` and `]` step the artifact list's scope tabs, Session and All. h, l and the arrows leave the scope alone.
    private static func testArtifactListTabsStepWithBrackets() throws {
        let artifact = ArtifactReference(kind: "html", path: "/tmp/first.html", label: "First", sessionID: "qm-a", addedAt: "")
        var snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        snapshot.tracker = TrackerSnapshot(repos: [
            TrackerRepo(id: "repo-a", name: "Alpha", sessions: [
                TrackerSession(id: "qm-a", title: "Alpha", repoName: "Alpha", workerCount: 0, artifacts: [artifact]),
            ]),
        ])
        let model = DockPaneModel()
        var scopes: [ArtifactScope] = []
        model.onSetArtifactScope = { scopes.append($0) }
        _ = model.apply(DockState(dockContent: .artifactList), snapshot: snapshot, preferredArtifactSessionID: "qm-a")
        var keys = ListKeyResolver()

        try expect(dockKey(try keyEvent("]", keyCode: 30), &keys, model, snapshot), "] should step the artifact tabs forward")
        try expect(scopes == [ArtifactDisplayState.movedScope(current: .session, delta: 1)], "] should step from Session to the next tab, got \(scopes)")
        try expect(!dockKey(try keyEvent("l", keyCode: 37), &keys, model, snapshot), "l should not step the tabs")
        try expect(!dockKey(try keyEvent("h", keyCode: 4), &keys, model, snapshot), "h should not step the tabs")
        try expect(!dockKey(try keyEvent("", keyCode: 124), &keys, model, snapshot), "→ should not step the tabs")
        try expect(!dockKey(try keyEvent("", keyCode: 123), &keys, model, snapshot), "← should not step the tabs")
        try expect(scopes.count == 1, "h, l and the arrows should leave the scope alone, got \(scopes)")
        try expect(dockKey(try keyEvent("[", keyCode: 33), &keys, model, snapshot), "[ should step the artifact tabs back")
        try expect(scopes.last == ArtifactDisplayState.movedScope(current: .session, delta: -1), "[ should step back from Session, got \(scopes)")
    }

    /// The tracker takes ↓ and ↑ as j and k do, and gg and G go to its first and last session. Each check reads the cursor
    /// back with `y`, which copies the selected session's ID.
    private static func testTrackerListKeysMoveTheCursor() throws {
        let size = CGSize(width: 340, height: 400)
        let store = RuntimeStore(sourceLabel: "test")
        store.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [
            TrackerRepo(id: "repo", name: "Repo", color: "indigo", sessions: [
                TrackerSession(id: "one", title: "One", repoName: "Repo", role: "master"),
                TrackerSession(id: "two", title: "Two", repoName: "Repo", role: "master"),
                TrackerSession(id: "three", title: "Three", repoName: "Repo", role: "master"),
            ]),
        ])))
        var copied: [String] = []
        let bridge = TrackerKeyboardBridge()
        let root = TrackerRootView(
            store: store,
            navigation: NavigationStore(state: AppNavigationState(focusedRegion: .tracker)),
            keyboardBridge: bridge,
            newSessionPresenter: NewSessionSheetPresenter(),
            destructiveConfirmationPresenter: DestructiveConfirmationPresenter(),
            onEffect: { effect in
                if case .copySessionID(let sessionID) = effect {
                    copied.append(sessionID)
                }
                return true
            }
        )
        .frame(width: size.width, height: size.height)
        .background(AppPalette.window.swiftUI)
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size, scale: 1)
        window.contentView = view
        window.show()
        defer { window.close() }
        try expect(waitUntil { bridge.handler != nil }, "the tracker should install its key handler")

        func cursor() throws -> String? {
            copied.removeAll()
            _ = bridge.handle(try keyEvent("y", keyCode: 16))
            return copied.last
        }
        try expect(try cursor() == "one", "the cursor should start on the first session")
        try expect(bridge.handle(try keyEvent("", keyCode: 125)), "↓ should move the tracker's cursor")
        try expect(try cursor() == "two", "↓ should move to the second session, got \(String(describing: copied.last))")
        try expect(bridge.handle(try keyEvent("j", keyCode: 38)), "j should move down")
        try expect(try cursor() == "three", "j should move to the third session")
        try expect(bridge.handle(try keyEvent("k", keyCode: 40)), "k should move up")
        try expect(try cursor() == "two", "k should move back to the second session")
        try expect(bridge.handle(try keyEvent("G", keyCode: 5, modifierFlags: [.shift])), "G should jump to the last session")
        try expect(try cursor() == "three", "G should select the last session")
        try expect(bridge.handle(try keyEvent("g", keyCode: 5)), "one g should arm gg")
        try expect(bridge.handle(try keyEvent("g", keyCode: 5)), "a second g should jump to the first session")
        try expect(try cursor() == "one", "gg should select the first session")
        try expect(!bridge.handle(try keyEvent("l", keyCode: 37)), "l should not move or open the tracker")
        try expect(try cursor() == "one", "l should leave the cursor alone")
        try expect(!bridge.handle(try keyEvent("[", keyCode: 33)), "the tracker has no tabs, so [ passes through")
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

        var keys = ListKeyResolver()
        try expect(dockKey(event, &keys, model, snapshot), "y should copy the selected artifact")
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

        var keys = ListKeyResolver()
        try expect(dockKey(try keyEvent(" ", keyCode: 49), &keys, model, snapshot), "Space should select the current artifact")
        try expect(dockKey(try keyEvent("j", keyCode: 38), &keys, model, snapshot), "j should select the next artifact")
        try expect(dockKey(try keyEvent(" ", keyCode: 49), &keys, model, snapshot), "Space should select another artifact")
        try expect(dockKey(try keyEvent("y", keyCode: 16), &keys, model, snapshot), "y should copy the selected artifacts")
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

        var keys = ListKeyResolver()
        try expect(dockKey(try keyEvent(" ", keyCode: 49), &keys, model, snapshot), "Space should select the current artifact")
        try expect(dockKey(try keyEvent("j", keyCode: 38), &keys, model, snapshot), "j should select the next artifact")
        try expect(dockKey(try keyEvent(" ", keyCode: 49), &keys, model, snapshot), "Space should select another artifact")
        try expect(dockKey(try keyEvent("d", keyCode: 2), &keys, model, snapshot), "d should delete the selected artifacts")
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
        var keys = ListKeyResolver()
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
            try expect(dockKey(event, &keys, model, snapshot, in: []), "artifact viewer back key should be handled")
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

        var keys = ListKeyResolver()
        try expect(dockKey(try keyEvent("y", keyCode: 16), &keys, model, snapshot, in: []), "viewer y should copy artifact path")
        try expect(pasteboard.string(forType: .string) == artifact.path, "viewer y should copy selected artifact path")
        try expect(copied, "viewer y should report copied artifact path")

        let beforeReload = model.artifactModel.reloadNonce
        try expect(dockKey(try keyEvent("r", keyCode: 15), &keys, model, snapshot, in: []), "viewer r should refresh")
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
        try expect(host.isHidden, "the modal host should stay hidden, and out of the way of clicks, while nothing is presented")

        holder.item = Item(id: "a")
        try expect(waitUntil { stack.entries.count == 1 && !host.isHidden && window.firstResponder === host }, "the in-window modal should mount and take focus")
        try expect(window.attachedSheet == nil, "presenting should not attach a system sheet window")
        try expect(stack.entries.count == 1, "presenting should push one in-window modal, got \(stack.entries.count)")
        try expect(!host.isHidden, "the modal host should show while a modal is presented")
        try expect(window.firstResponder === host, "the modal host should take the keys from whatever had them")
        try expect(window.frame.size == windowSize, "a presented modal must not resize the window, got \(window.frame.size) from \(windowSize)")

        holder.item = nil
        try expect(waitUntil { stack.isEmpty }, "a dismissed modal should stop counting as open at once, so keys go back underneath")
        try expect(stack.entries.count == 1 && stack.entries[0].closing, "a dismissed modal should stay mounted, closing, while it fades out")
        try expect(!host.isHidden, "the host should stay visible until the fade-out ends")
        try expect(waitUntil { stack.entries.isEmpty && host.isHidden }, "the modal fade-out should finish and hide the host")
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
        func pressEsc() {
            guard let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
                return
            }
            NSApp.sendEvent(esc)
        }
        window.makeFirstResponder(terminal)
        try expect(waitUntil { window.firstResponder === terminal }, "the terminal should start with the keys")

        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: QuestLogFilter(), pageScroll: QuestLogPageScroll(), onCommand: { command in
            guard command == .close else {
                return
            }
            store.close()
            stack.dismiss(id: QuestLogModal.stackID)
        }))
        try expect(waitUntil { stack.top?.kind == .questLog && window.firstResponder === host }, "the Quest Log should mount and take focus")
        try expect(stack.top?.kind == .questLog, "the Quest Log should be an entry on the modal stack")
        try expect(window.firstResponder === host, "the open Quest Log should hold the keys, not the terminal")
        try expect(stack.route(.newSession) == .ignored && stack.route(.settings) == .ignored, "a global New Session or Settings over the Quest Log should be ignored")
        try expect(stack.route(.toggleQuestLog) == .allowed, "the Quest Log's toggle should act on it while it's on top")

        // Send forth's New Session: a child the log opens itself goes on top, and Esc closes it first.
        newSession.present(initialPath: "/tmp", mutationClient: StubMutationClient(result: .failure(TestFailure("unused"))), directoryClient: nil, onSuccess: { _ in })
        try expect(waitUntil { stack.entries.count == 2 && stack.entries.last?.kind == .other }, "New Session should mount over the Quest Log")
        try expect(stack.entries.count == 2 && stack.entries.last?.kind == .other, "the child should draw on top of the Quest Log, got \(stack.entries.map(\.kind))")
        try expect(stack.route(.toggleQuestLog) == .ignored, "the Quest Log's toggle should do nothing while a child is on top")
        pressEsc()
        try expect(waitUntil { newSession.presentation == nil && stack.entries.count == 1 }, "Esc should finish closing the child modal")
        try expect(newSession.presentation == nil, "the first Esc should close the child on top")
        try expect(store.isOpen && stack.top?.kind == .questLog, "the first Esc should leave the Quest Log open")

        // ⌘T over the log: New Quest opens as its child, and Esc closes it alone.
        try expect(stack.route(.newQuest) == .child, "⌘T over the Quest Log should open New Quest as its child")
        newQuest.item = Item(id: "new-quest")
        try expect(waitUntil { stack.entries.count == 2 && stack.entries.last?.kind == .other }, "New Quest should mount over the Quest Log")
        try expect(stack.entries.last?.kind == .other && stack.entries.filter { !$0.closing }.count == 2, "New Quest should open on top of the Quest Log")
        pressEsc()
        try expect(waitUntil { newQuest.item == nil && stack.entries.count == 1 }, "Esc should finish closing New Quest")
        try expect(newQuest.item == nil && store.isOpen, "Esc should close New Quest and leave the Quest Log open")

        pressEsc()
        try expect(waitUntil { !store.isOpen && stack.entries.isEmpty && host.isHidden && window.firstResponder === terminal }, "the Quest Log should close and restore terminal focus")
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
            func connect(to config: TerminalLaunchConfig, completion: @escaping (Result<String?, Error>) -> Void) { completion(.success(config.tmuxSession)) }
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
                actionBar: { nil },
                trackerHosting: { tracker },
                dockView: { nil },
                watcherPane: { nil },
                terminalHost: { terminal },
                modalHost: { host },
                updateDockTabs: {}
            )
            host.onEmpty = { coordinator.focusCurrentRegion() }
            window.show(key: true)
            defer { window.close() }
            var responders: [NSResponder?] = []
            let observation = window.observe(\.firstResponder, options: [.new]) { window, _ in
                MainActor.assumeIsolated { responders.append(window.firstResponder) }
            }
            defer { observation.invalidate() }

            coordinator.focus(.terminal)
            try expect(waitUntil { window.firstResponder === terminal.view }, "\(start): the terminal should take focus before the sheet opens")
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
            var dismissalCompleted = false
            stack.present(id: id, AnyView(NewSessionSheetView(
                presentation: presentation,
                dismiss: { stack.dismiss(id: id, onDismissed: { dismissalCompleted = true }) }
            )))
            let expected = start == .prompt ? "ModalPromptEditorTextView" : "SinkView"
            try expect(waitUntil {
                let holder = String(describing: window.firstResponder.map { type(of: $0) })
                return !host.isHidden && holder.contains(expected)
                    && subviews(of: host).contains { $0 is SheetKeyEventMonitor.MonitorView }
            }, "\(start): the sheet should mount its key monitor and focus \(expected)")
            let holder = String(describing: window.firstResponder.map { type(of: $0) })
            try expect(holder.contains(expected), "\(start): the sheet should start with \(expected) focused, got \(holder)")

            // ⌘Return, through the sheet's own key handler, as the user summons.
            guard let monitor = subviews(of: host).compactMap({ $0 as? SheetKeyEventMonitor.MonitorView }).first else {
                throw TestFailure("\(start): the sheet's key monitor never mounted")
            }
            let submitted = responders.count
            _ = monitor.onKeyDown(try keyEvent("\r", keyCode: 36, modifierFlags: .command))
            try expect(waitUntil {
                summoned == "qm-new" && dismissalCompleted && stack.entries.isEmpty && host.isHidden && window.firstResponder === terminal.view
            }, "\(start): dismissal should complete and restore terminal focus")
            try waitForMainQueueTurn()
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
            func connect(to config: TerminalLaunchConfig, completion: @escaping (Result<String?, Error>) -> Void) { completion(.success(config.tmuxSession)) }
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
            actionBar: { nil },
            trackerHosting: { tracker },
            dockView: { nil },
            watcherPane: { nil },
            terminalHost: { terminal },
            modalHost: { host },
            updateDockTabs: {}
        )
        host.onEmpty = { coordinator.focusCurrentRegion() }
        window.show(key: true)
        defer { window.close() }
        func presentModal() throws {
            stack.present(id: "modal", AnyView(Color.clear.frame(width: 120, height: 80)))
            try expect(waitUntil { !host.isHidden && window.firstResponder === host }, "the modal should mount and take focus")
        }
        coordinator.focus(.tracker)
        try expect(waitUntil { window.firstResponder === tracker }, "the tracker should start with the keys")

        // New Session's Summon: close(), then onSuccess's switchTerminal focuses the new terminal at once.
        try presentModal()
        stack.dismiss(id: "modal")
        coordinator.focusTerminal()
        try expect(window.firstResponder === host, "a focus request during the fade-out should leave the keys on the host")
        try expect(waitUntil { stack.entries.isEmpty && window.firstResponder === terminal.view }, "the terminal should take focus after the modal fades")
        try expect(window.firstResponder === terminal.view, "after Summon the terminal should have the keys, got \(String(describing: window.firstResponder))")

        coordinator.focus(.tracker)
        try presentModal()
        coordinator.focusTerminal()
        try expect(window.firstResponder === host, "focusing the terminal (⌥⌘2, a session switch) under a modal should leave the keys on it, got \(String(describing: window.firstResponder))")
        coordinator.focusRegionLeft()
        try expect(window.firstResponder === host, "a region move (⇧⌘H) under a modal should leave the keys on it, got \(String(describing: window.firstResponder))")
        try expect(navigation.focusedRegion == .tracker, "the region move should still update navigation")
        coordinator.focusTerminal()
        stack.dismiss(id: "modal")
        try expect(waitUntil { stack.entries.isEmpty && window.firstResponder === terminal.view }, "the last focus request should take effect after the modal fades")
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
            actionBar: { nil },
            trackerHosting: { tracker },
            dockView: { nil },
            watcherPane: { nil },
            terminalHost: { nil },
            modalHost: { host },
            updateDockTabs: {}
        )
        host.onEmpty = { coordinator.focusCurrentRegion() }
        host.onDrawingChange = { coordinator.updateRegionKeys() }
        window.show(key: true)
        defer { window.close() }

        coordinator.focus(.dock)
        try expect(dock.isFocused, "the dock's frame should lift while the dock has focus")
        coordinator.focus(.tracker)
        try expect(!dock.isFocused, "the frame should drop when focus leaves the dock")

        coordinator.focus(.dock)
        stack.present(id: "modal", AnyView(Color.clear.frame(width: 120, height: 80)))
        try expect(waitUntil { !dock.isFocused }, "a modal should drop the focused dock's frame")
        try expect(!dock.isFocused, "a modal over the focused dock should drop its frame")
        stack.dismiss(id: "modal")
        try expect(waitUntil { dock.isFocused }, "the focused dock should lift its frame after the modal fades")
        try expect(dock.isFocused, "the frame should lift again once the modal has faded")

        coordinator.focus(.tracker)
        stack.present(id: "modal", AnyView(Color.clear.frame(width: 120, height: 80)))
        try expect(waitUntil { !dock.isFocused }, "a modal should keep the unfocused dock's frame down")
        coordinator.focus(.dock)
        try expect(!dock.isFocused, "a dock focus request deferred under a modal should not light the frame")
        stack.dismiss(id: "modal")
        try expect(waitUntil { dock.isFocused }, "the deferred dock focus should light after the modal fades")
        try expect(dock.isFocused, "the deferred dock focus should light the frame once the modal has faded")
    }

    /// With no suggestion open, Return moves the cursor to the filter's first match and hands the keys back to the
    /// list; the quest isn't edited and the filter keeps its text. Esc does the handing back without moving the cursor.
    private static func testQuestLogFilterReturnAndEscHandBackToTheList() throws {
        let quests = [
            QuestItem(id: "q1", content: "Write the plan", projectID: "p", projectName: "p"),
            QuestItem(id: "q2", content: "Fix the bug", projectID: "p", projectName: "p"),
            QuestItem(id: "q3", content: "Write the report", projectID: "p", projectName: "p"),
        ]
        let store = QuestLogStore()
        let filter = QuestLogFilter()
        var sent: [ListCommand] = []
        var leaves = 0
        filter.onChange = { store.sync(quests: quests, repos: [], filter: filter.search) }
        filter.onMoveSelection = { command in
            sent.append(command)
            _ = store.handle(command)
        }
        filter.onLeave = { leaves += 1 }
        store.sync(quests: quests, repos: [])
        filter.setQuery("write")
        try expect(filter.suggestions.isEmpty, "a text query should show no suggestions")
        store.select("q3")

        try expect(filter.handleCommand(.plain(36)), "Return should be the filter's when no suggestion shows")
        try expect(store.selectedID == "q1", "Return should put the cursor on the first match, got \(String(describing: store.selectedID))")
        try expect(sent == [.jumpToTop] && leaves == 1, "Return should only move the cursor and hand the keys back, sent \(sent)")
        try expect(filter.query == "write", "Return should keep the filter applied, got \(filter.query)")

        try expect(!filter.handleCommand(.plain(125)), "↓ should be the caret's when no suggestion shows: the list moves with j and k")
        try expect(store.selectedID == "q1", "↓ should leave the cursor on the first match, got \(String(describing: store.selectedID))")
        try expect(filter.handleCommand(Keymap.KeyPress(keyCode: 45, character: "n", modifiers: [.control])) && store.selectedID == "q3", "⌃n should move the list down with no suggestion showing, got \(String(describing: store.selectedID))")
        try expect(filter.handleCommand(Keymap.KeyPress(keyCode: 35, character: "p", modifiers: [.control])) && store.selectedID == "q1", "⌃p should move the list back up with no suggestion showing")
        try expect(filter.handleCommand(.plain(48)) && store.selectedID == "q1", "Tab should take the press and move nothing: the filter is the Quest Log's one field")
        try expect(!filter.handleCommand(Keymap.KeyPress(keyCode: 38, character: "j")), "j should type into the filter, not move the list")

        try expect(filter.handleCommand(.plain(53)), "Esc should be the filter's when no suggestion shows")
        try expect(leaves == 2 && store.selectedID == "q1" && filter.query == "write", "Esc should hand the keys back and keep the cursor and the filter")
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
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: filter, pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        try expect(waitUntil { !host.isHidden && window.firstResponder === host && findKeyField(in: host) != nil }, "the Quest Log filter should mount under its modal")
        filter.focus()
        try expect(waitUntil { (window.firstResponder as? NSTextView)?.isFieldEditor == true }, "the filter should take focus")
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
            throw TestFailure("the filter should take focus, got \(String(describing: window.firstResponder))")
        }
        editor.insertText("ab", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        let field = editor.delegate as? NSTextField

        stack.present(id: "new-quest", AnyView(Color.clear.frame(width: 120, height: 80)))
        try expect(waitUntil { stack.entries.count == 2 && window.firstResponder === host }, "the child should mount over the filter")
        try expect(window.firstResponder === host, "the child should take the keys from the filter")
        stack.dismiss(id: "new-quest")
        try expect(waitUntil {
            stack.entries.count == 1 && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }, "the filter should regain focus after the child closes")
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
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: filter, pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        try expect(waitUntil { !host.isHidden && window.firstResponder === host && findKeyField(in: host) != nil }, "the Quest Log filter should mount under its modal")
        filter.focus()
        try expect(waitUntil { (window.firstResponder as? NSTextView)?.isFieldEditor == true }, "the filter should take focus")
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
            throw TestFailure("the filter should take focus, got \(String(describing: window.firstResponder))")
        }
        editor.insertText("abcd", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 2))

        stack.present(id: "new-quest", AnyView(Color.clear.frame(width: 120, height: 80)))
        try expect(waitUntil { stack.entries.count == 2 && window.firstResponder === host }, "the child should mount over the filter")
        stack.dismiss(id: "new-quest")
        try expect(waitUntil {
            stack.entries.count == 1 && (window.firstResponder as? NSTextView)?.isFieldEditor == true
        }, "the filter should regain focus after the child closes")
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
        window.makeFirstResponder(field)
        try expect(waitUntil { field.currentEditor() != nil }, "the field editor should mount before typing")
        guard let editor = field.currentEditor() as? NSTextView else {
            throw TestFailure("the field should take focus")
        }
        editor.insertText("foo", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 1, length: 0))

        stack.present(id: "modal", AnyView(Color.clear.frame(width: 120, height: 80)))
        try expect(waitUntil { window.firstResponder === host }, "the modal should take focus from the field")
        try expect(window.firstResponder === host, "the modal should take the keys from the field")
        stack.dismiss(id: "modal")
        try expect(waitUntil { stack.entries.isEmpty && (window.firstResponder as? NSTextView)?.isFieldEditor == true }, "the field should regain focus after the last modal fades")
        guard let restored = window.firstResponder as? NSTextView, restored.isFieldEditor, restored.delegate as? NSTextField === field else {
            throw TestFailure("the last modal fading should refocus the field, got \(String(describing: window.firstResponder))")
        }
        try expect(restored.string == "foo" && restored.selectedRange() == NSRange(location: 1, length: 0), "the field should keep its text and caret, got \(restored.string) \(restored.selectedRange())")
    }

    /// The log is rebuilt per opening; it opens scrolled to the selection it kept, not at the top.
    /// A freshly opened log lists its first row whole below the filter, in the window's shell as the render draws it.
    /// A native scroll view left under a scale animation keeps the offset the scale leaves, so the modal must not scale
    /// over the list while it appears.
    private static func testQuestLogListStartsWithItsFirstRowWhole() throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { ((($0 as? NSScrollView).map { [$0] }) ?? []) + scrollViews(in: $0) }
        }
        let size = CGSize(width: 1440, height: 900)
        let shell = RenderPreview.questLogWindowView()
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        shell.frame = container.bounds
        container.addSubview(shell)
        let window = HeadlessWindow(size: size)
        window.contentView = container
        window.show()
        defer { window.close() }
        try expect(waitUntil { !scrollViews(in: shell).isEmpty }, "the Quest Log should mount its list")
        shell.layoutSubtreeIfNeeded()
        let layout = QuestLogLayout(sheetSize: QuestLogMetrics.sheetSize)
        let listSize = CGSize(width: layout.listWidth, height: layout.listHeight)
        guard let list = scrollViews(in: shell).first(where: { $0.frame.size == listSize }) else {
            throw TestFailure("the Quest Log should have a list scroll view of \(listSize)")
        }
        let offset = list.contentView.bounds.origin.y
        let topInset = list.contentInsets.top
        try expect(
            abs(offset + topInset) < 0.5,
            "a list at its top should show its first row whole: scroll offset \(offset), top inset \(topInset)"
        )
    }

    /// A modal fitted below 1 must route events where it draws. A 700 x 600 window fits the fixed sheet (1280 x 860) at
    /// 0.516; the filter field's centre, converted through AppKit's own conversions, must reach the modal.
    private static func testQuestLogFilterFieldTakesClicksWhenTheModalIsScaledDown() throws {
        func textFields(in view: NSView) -> [NSTextField] {
            view.subviews.flatMap { ((($0 as? NSTextField).map { [$0] }) ?? []) + textFields(in: $0) }
        }
        let store = QuestLogStore()
        store.sync(quests: [QuestItem(id: "q1", content: "Quest 1")], repos: [])
        let size = CGSize(width: 700, height: 600)
        let window = HeadlessWindow(size: size)
        let stack = InWindowModalStack()
        let host = InWindowModalHost(stack: stack)
        host.frame = .zero
        window.contentView = host
        window.show()
        defer { window.close() }
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: QuestLogFilter(), pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        host.frame = NSRect(origin: .zero, size: size)
        try expect(waitUntil { !hasAnimations(in: host.layer) && !textFields(in: host).isEmpty }, "the Quest Log's filter field should appear")
        guard let field = textFields(in: host).first else {
            throw TestFailure("the Quest Log should have a text field")
        }
        let centre = NSPoint(x: field.bounds.midX, y: field.bounds.midY)
        let inWindow = field.convert(centre, to: nil)
        try expect(NSRect(origin: .zero, size: size).contains(inWindow), "the field's centre should be in the window, got \(inWindow)")
        let inHost = host.convert(inWindow, from: nil)
        let backInWindow = host.convert(inHost, to: nil)
        try expect(
            abs(backInWindow.x - inWindow.x) < 0.5 && abs(backInWindow.y - inWindow.y) < 0.5,
            "converting to the host and back should return the same point, got \(backInWindow) for \(inWindow)"
        )
        // AppKit's own conversion carries the fit: the field's window width is its width times the fit.
        let fit = min(
            (size.width - 2 * ShellMetrics.gap) / QuestLogMetrics.sheetSize.width,
            (size.height - 2 * ShellMetrics.gap) / QuestLogMetrics.sheetSize.height
        )
        let windowWidth = field.convert(field.bounds, to: nil).width
        try expect(
            abs(windowWidth / field.bounds.width - fit) < 0.01,
            "the field should draw at the fit \(fit) in the window, got \(windowWidth / field.bounds.width)"
        )
        // A click on the field's centre reaches the modal. SwiftUI routes events inside its hosting view, so the field
        // itself need not be the deepest AppKit hit.
        let hit = window.contentView?.superview?.hitTest(inWindow)
        try expect(
            hit.map { $0 === host || $0.isDescendant(of: host) } ?? false,
            "a click on the field's centre should reach the modal, got \(String(describing: hit))"
        )
    }

    /// The Quest Log in a 1000 x 800 window, read frame by frame. The modal's drawn rect comes from the presentation of the
    /// layer that carries its scale, so an entrance or a close in flight shows.
    @MainActor private struct QuestLogModalFrames {
        // One point per pixel, as the CI runner renders: at a fractional fit that is where Auto Layout rounds frames.
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 800), scale: 1)
        let stack = InWindowModalStack()
        let host: InWindowModalHost
        let store: QuestLogStore

        init() {
            store = QuestLogStore()
            store.sync(quests: [QuestItem(id: "q1", content: "Quest 1")], repos: [])
            host = InWindowModalHost(stack: stack)
            host.frame = NSRect(origin: .zero, size: window.frame.size)
            window.contentView = host
            window.show()
        }

        /// The hosted content's hosting view, which the modal file keeps private: found by class name.
        var hostedView: NSView? { Self.view(named: "ModalHostingView", in: host) }

        /// The view whose layer carries the modal's scale: the hosted content's superview.
        var coordinateView: NSView? { hostedView?.superview }

        /// Whether the entrance (or a close) is running: no click reaches the modal then.
        var isScaling: Bool { !(coordinateView?.layer?.animationKeys() ?? []).isEmpty }

        /// The Quest Log's laid-out content at the fit to the window, centred. The fit reads the frame the content is drawn
        /// at: on a busy runner SwiftUI's reported intrinsic size can differ from that frame.
        var fittedRect: CGRect {
            let content = hostedView?.frame.size ?? .zero
            let margin = ShellMetrics.gap * 2
            let fit = min(1, (host.bounds.width - margin) / content.width, (host.bounds.height - margin) / content.height)
            let size = CGSize(width: content.width * fit, height: content.height * fit)
            return CGRect(x: host.bounds.midX - size.width / 2, y: host.bounds.midY - size.height / 2, width: size.width, height: size.height)
        }

        func present() {
            store.open()
            stack.presentQuestLog(QuestLogModal(store: store, filter: QuestLogFilter(), pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        }

        /// Where the modal's content is drawn now, in the host's coordinates; nil while SwiftUI hasn't drawn it yet.
        var drawnRect: CGRect? {
            guard let coordinates = coordinateView, let hosted = hostedView, let coordinateLayer = coordinates.layer, let hostLayer = host.layer else {
                return nil
            }
            let presented = coordinateLayer.presentation() ?? coordinateLayer
            let corners = [CGPoint(x: hosted.frame.minX, y: hosted.frame.minY), CGPoint(x: hosted.frame.maxX, y: hosted.frame.maxY)]
                .map { presented.convert($0, to: hostLayer) }
            return CGRect(
                x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                width: abs(corners[1].x - corners[0].x), height: abs(corners[1].y - corners[0].y)
            )
        }

        /// Lays out the host synchronously, so the frames read next are the laid-out ones.
        func layOutNow() {
            host.layoutSubtreeIfNeeded()
        }

        /// Presents the Quest Log and reads its drawn rect on each display tick until the entrance has run and finished, or
        /// five seconds pass. `perFrame` gets each drawn rect, and the rects are returned.
        func sampleEntrance(perFrame: (CGRect) throws -> Void = { _ in }) throws -> [CGRect] {
            present()
            var drawn: [CGRect] = []
            var began = false
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60))
                began = began || isScaling
                if let rect = drawnRect {
                    drawn.append(rect)
                    try perFrame(rect)
                }
                if began && !isScaling {
                    break
                }
            }
            return drawn
        }

        /// Dismisses the Quest Log and reads its drawn rect on each display tick until it is removed, or five seconds pass.
        func sampleClose() throws -> [CGRect] {
            stack.dismiss(id: QuestLogModal.stackID)
            var drawn: [CGRect] = []
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, coordinateView != nil {
                RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60))
                if let rect = drawnRect {
                    drawn.append(rect)
                }
            }
            return drawn
        }

        /// Presents the Quest Log with Reduce Motion on, then reads its drawn rect on the next few display ticks.
        func sampleRestingFrames(perFrame: (CGRect) throws -> Void) throws -> [CGRect] {
            present()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, drawnRect == nil {
                RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60))
            }
            var drawn: [CGRect] = []
            for _ in 0..<5 {
                RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60))
                if let rect = drawnRect {
                    drawn.append(rect)
                    try perFrame(rect)
                }
            }
            return drawn
        }

        private static func view(named name: String, in root: NSView) -> NSView? {
            if String(describing: type(of: root)) == name {
                return root
            }
            return root.subviews.lazy.compactMap { view(named: name, in: $0) }.first
        }
    }

    private static func sameRect(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.minX - rhs.minX) < tolerance && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance && abs(lhs.height - rhs.height) < tolerance
    }

    /// The entrance scales the modal about its centre. Its drawn rect keeps the window's centre at every frame, it starts a
    /// little smaller than the fit and never overshoots it, and it ends exactly at the fit.
    private static func testModalEntranceScalesAboutItsCentre() throws {
        let scene = QuestLogModalFrames()
        defer { scene.window.close() }
        let drawn = try scene.sampleEntrance()
        guard let smallest = drawn.map(\.width).min() else {
            throw TestFailure("the Quest Log should be drawn while it enters")
        }
        try expect(!scene.isScaling, "the entrance should finish")
        scene.layOutNow()
        // The sheet is a fixed size: the scaled layout must not shorten it (Auto Layout rounds its frame at a fractional fit).
        let laidOut = scene.hostedView?.frame.size ?? .zero
        try expect(
            abs(laidOut.width - QuestLogMetrics.sheetSize.width) < 0.5 && abs(laidOut.height - QuestLogMetrics.sheetSize.height) < 0.5,
            "the Quest Log should lay out at its fixed sheet size \(QuestLogMetrics.sheetSize), got \(laidOut)"
        )
        let fitted = scene.fittedRect
        let settled = scene.drawnRect ?? .zero
        try expect(sameRect(settled, fitted), "the entrance should end at the fit \(fitted), drawn \(settled)")
        try expect(smallest < fitted.width - 1, "the entrance should draw the modal smaller than the fit at first, smallest \(smallest)")
        try expect(smallest >= fitted.width * 0.96, "the entrance should start from about 0.97 of the fit, smallest \(smallest) of \(fitted.width)")
        try expect(drawn.allSatisfy { $0.width <= fitted.width + 0.5 }, "the entrance should never draw the modal above the fit")
        let centre = CGPoint(x: scene.host.bounds.midX, y: scene.host.bounds.midY)
        for rect in drawn {
            try expect(
                abs(rect.midX - centre.x) < 0.5 && abs(rect.midY - centre.y) < 0.5,
                "the modal should stay centred on \(centre) while it scales, but was drawn at \(rect)"
            )
        }
    }

    /// While the entrance runs nothing in the modal takes a click, so none lands on a control at the wrong place. Once it
    /// has settled a click just inside the drawn edge reaches the modal, and one just outside doesn't.
    private static func testModalEntranceRoutesClicksToWhereItDraws() throws {
        let scene = QuestLogModalFrames()
        defer { scene.window.close() }
        // The scale view covers the window, so a click outside the modal lands on it; only the hosted content counts as the modal.
        func reachesModal(_ point: CGPoint) -> Bool {
            let inWindow = scene.host.convert(point, to: nil)
            guard let hit = scene.window.contentView?.superview?.hitTest(inWindow), let hosted = scene.hostedView else {
                return false
            }
            return hit === hosted || hit.isDescendant(of: hosted)
        }
        var scalingFrames = 0
        let drawn = try scene.sampleEntrance { rect in
            guard scene.isScaling else {
                return
            }
            scalingFrames += 1
            try expect(!reachesModal(CGPoint(x: rect.midX, y: scene.host.bounds.midY)), "no click should reach the modal while it scales")
        }
        try expect(scalingFrames > 0, "the entrance should be sampled while it runs")
        try expect(drawn.last != nil, "the Quest Log should be drawn once the sample ends")
        try expect(!scene.isScaling, "the entrance should finish")
        scene.layOutNow()
        let fitted = scene.fittedRect
        let y = scene.host.bounds.midY
        try expect(reachesModal(CGPoint(x: fitted.minX + 4, y: y)), "a click 4pt inside the settled edge should reach the modal, drawn at \(fitted)")
        try expect(!reachesModal(CGPoint(x: fitted.minX - 4, y: y)), "a click 4pt outside the settled edge should not reach the modal, drawn at \(fitted)")
    }

    /// Under Reduce Motion the modal is drawn at its fit from its first frame, and nothing animates.
    private static func testModalEntranceIsSkippedUnderReduceMotion() throws {
        let reducesMotion = Motion.reducesMotion
        Motion.reducesMotion = { true }
        defer { Motion.reducesMotion = reducesMotion }
        let scene = QuestLogModalFrames()
        defer { scene.window.close() }
        var animated = false
        let drawn = try scene.sampleRestingFrames { _ in
            animated = animated || scene.isScaling
        }
        try expect(!drawn.isEmpty, "the Quest Log should be drawn under Reduce Motion")
        try expect(!animated, "under Reduce Motion the entrance should add no animation")
        scene.layOutNow()
        let fitted = scene.fittedRect
        try expect(sameRect(scene.drawnRect ?? .zero, fitted), "under Reduce Motion the modal should be drawn at the fit \(fitted)")
        // The first frame is already the fit's width, within the layout's own settling.
        if let first = drawn.first {
            try expect(abs(first.width - fitted.width) < fitted.width * 0.01, "under Reduce Motion the first frame should already be the fit's width, got \(first.width) of \(fitted.width)")
        }
    }

    /// Closing scales the modal back to its start scale about its centre, before it is removed.
    private static func testModalCloseScalesBackAboutItsCentre() throws {
        let scene = QuestLogModalFrames()
        defer { scene.window.close() }
        _ = try scene.sampleEntrance()
        try expect(!scene.isScaling, "the Quest Log should be drawn at rest before it closes")
        scene.layOutNow()
        let fitted = scene.fittedRect
        let drawn = try scene.sampleClose()
        guard let smallest = drawn.map(\.width).min() else {
            throw TestFailure("the Quest Log should be drawn while it closes")
        }
        try expect(smallest < fitted.width - 1, "the close should draw the modal smaller than the fit, smallest \(smallest)")
        try expect(smallest >= fitted.width * 0.96, "the close should end at about 0.97 of the fit, smallest \(smallest) of \(fitted.width)")
        let centre = CGPoint(x: scene.host.bounds.midX, y: scene.host.bounds.midY)
        for rect in drawn {
            try expect(
                abs(rect.midX - centre.x) < 0.5 && abs(rect.midY - centre.y) < 0.5,
                "the modal should stay centred on \(centre) while it closes, but was drawn at \(rect)"
            )
        }
    }

    private static func testQuestLogOpensScrolledToTheKeptSelection() throws {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { ((($0 as? NSScrollView).map { [$0] }) ?? []) + scrollViews(in: $0) }
        }
        let store = QuestLogStore()
        store.sync(quests: (1...40).map { QuestItem(id: "q\($0)", content: "Quest \($0)", projectID: "p", projectName: "p") }, repos: [])
        _ = store.handle(.jumpToBottom)
        let window = HeadlessWindow(size: CGSize(width: 1000, height: 860))
        let stack = InWindowModalStack()
        let host = InWindowModalHost(stack: stack)
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 860)
        window.contentView = host
        window.show()
        defer { window.close() }
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: QuestLogFilter(), pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        try expect(waitUntil {
            !hasAnimations(in: host.layer) && scrollViews(in: host).contains { list in
                guard let height = list.documentView?.frame.height else {
                    return false
                }
                return height > list.contentView.bounds.height && list.contentView.bounds.origin.y > 0
            }
        }, "the Quest Log should finish laying out and scroll to the kept selection")
        // The tab row and the page's ink scroll too; the list is the tallest document.
        let list = scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
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

        window.makeFirstResponder(field)
        try expect(waitUntil { reported.last == true && field.hasFocus }, "taking focus should light the field")
        window.makeFirstResponder(nil)
        try expect(waitUntil { reported.last == false && !field.hasFocus }, "Esc (focus to nil) should clear the field")
        window.makeFirstResponder(field)
        try expect(waitUntil { reported.last == true && field.hasFocus }, "the field should light when it takes focus again")
        window.makeFirstResponder(other)
        try expect(waitUntil { reported.last == false && !field.hasFocus }, "focus moving elsewhere should clear the field")
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
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try pumpOneMainRunLoopTurn()
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
    @MainActor
    private final class TrackerFixture {
        let store: RuntimeStore
        let view: NSView
        let window: HeadlessWindow
        let size: CGSize

        init(masters: Int, shells: Int, viewed: String?, height: Int, sessionClass: String = "", shellRole: String = "shell", workers: Int = 0) throws {
            func session(_ id: String, role: String) -> TrackerSession {
                TrackerSession(id: id, title: id, repoName: "Repo", repoColor: "indigo", sessionClass: role == "master" ? sessionClass : "", agent: role == "shell" ? "shell" : "codex", role: role, state: "idle", parentID: role == "worker" ? "master-0" : "")
            }
            let plates = (0..<masters).map { session("master-\($0)", role: "master") }
                + (0..<workers).map { session("worker-\($0)", role: "worker") }
            let shellRows = (0..<shells).map { session("shell-\($0)", role: shellRole) }
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
            let shellSectionHeight = min(CGFloat(shells) * TrackerShellMetrics.rowHeight, TrackerShellMetrics.maxHeight)
            try expect(LogicSelfTests.waitUntil {
                if shells > 0 { return scrollView(height: shellSectionHeight) != nil }
                return LogicSelfTests.descendants(of: view).contains { $0 is NSScrollView && $0.bounds.height > 0 }
            }, "the tracker footer should finish laying out")
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

        /// The lower half of the 20pt banner-to-shell gap is clear; the upper half leaves room for the raised shadow.
        func clearBand(above sectionTop: Int) -> Bool {
            let clearTop = sectionTop - Int(Space.item)
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
    /// with few or many plates the banner ends `Space.section` above it, and with
    /// many shells the section stops at its max height. The viewed shell's filled row marks the section's bottom (the
    /// last shell) or its top (the first).
    private static func testTheShellSectionIsPinnedToTheTrackersBottom() throws {
        let height = 700
        let bottom = height - Int(TrackerListMetrics.verticalPadding) - 1
        let rowHeight = Int(TrackerShellMetrics.rowHeight)
        func probe(masters: Int, shells: Int, viewed: String) throws -> PixelProbe {
            let fixture = try TrackerFixture(masters: masters, shells: shells, viewed: viewed, height: height)
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
        let last = try TrackerFixture(masters: 14, shells: shells, viewed: "shell-13", height: height)
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
        let first = try TrackerFixture(masters: 14, shells: shells, viewed: "shell-0", height: height)
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
        let moved = try TrackerFixture(masters: 14, shells: shells, viewed: "shell-0", height: height)
        defer { moved.close() }
        guard let movedScroll = moved.scrollView(height: TrackerShellMetrics.maxHeight) else {
            throw TestFailure("no 175pt scroll view after the viewed session moved")
        }
        moved.store.setCurrentTerminalSessionID("shell-13")
        try expect(waitUntil { abs(offsetFromTop(movedScroll) - (contentHeight - TrackerShellMetrics.maxHeight)) < 0.5 }, "the viewed last shell should scroll into view")
        try expect(abs(offsetFromTop(movedScroll) - (contentHeight - TrackerShellMetrics.maxHeight)) < 0.5, "the cursor onto the last shell should scroll it into view, got \(offsetFromTop(movedScroll))")

        // A cursor the pointer moved is already under it: no scroll.
        let hovered = try TrackerFixture(masters: 14, shells: shells, viewed: "shell-0", height: height)
        defer { hovered.close() }
        PointerHighlight.cursor.pointerMoved(to: "shell-13")
        hovered.store.setCurrentTerminalSessionID("shell-13")
        try waitForMainQueueTurn()
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
        func borderRows(_ view: NSView, size: CGSize, x: Int, startingAt startY: Int = 0, atLeast count: Int) throws -> [Int] {
            view.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: size, scale: 1)
            window.contentView = view
            window.show()
            defer { window.close() }
            guard let line = AppPalette.line.usingColorSpace(.deviceRGB) else {
                throw TestFailure("could not make a bitmap")
            }
            func capture() -> [Int]? {
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else {
                    return nil
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
            var rendered: [Int] = []
            try expect(waitUntil {
                rendered = capture() ?? []
                return rendered.filter { $0 >= startY }.count >= count
            }, "at least \(count) spacing border pixels should render at x \(x) from row \(startY)")
            return rendered
        }

        // Inside the tile, past its 5pt corner and clear of its glyph: the gutter, the tile's inset, and 6.
        let tileColumn = Int(Space.section + Space.item) + 6
        let pane = CGSize(width: DockWidthPreference.panelWidth, height: 1015)
        let paneRows = try borderRows(RenderPreview.artifactPaneView(highlight: nil), size: pane, x: tileColumn, atLeast: 22)
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
        let fieldEdges = try borderRows(form, size: formSize, x: fieldColumn, startingAt: Int(ModalSheetHeader.height), atLeast: 2)
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
        let discRows = try borderRows(titleForm, size: titleSize, x: discColumn, startingAt: Int(ModalSheetHeader.height), atLeast: 2)
        try expect(discRows.first == rowTop && discRows.contains(rowTop + 39), "the portrait disc should be 40 high from the row's top, got rows \(discRows)")
        let titleColumn = Int(ModalFormMetrics.inset + SessionPortraitMetrics.sheetDiameter + Space.item + Space.section)
        let titleRows = try borderRows(titleForm, size: titleSize, x: titleColumn, startingAt: Int(ModalSheetHeader.height), atLeast: 2)
        try expect(titleRows.first == rowTop && titleRows.contains(rowTop + Int(FormFieldMetrics.height) - 1), "the title field should be 35 high from the row's top, got rows \(titleRows)")
        let nextTop = rowTop + Int(SessionPortraitMetrics.sheetDiameter + ModalFormMetrics.fieldSpacing)
        try expect(titleRows.contains(nextTop) && !titleRows.contains(nextTop - 1), "the next field should start 20 under the disc, got rows \(titleRows)")
    }

    /// The elevation shadows (AGENTS.md, "Interaction states") reach past the clip that shapes their panel: a modal's
    /// (`modal`) from `scoopedPanel`, the dock's (`raised`, 1.5 down) from `ScoopedLayerChrome`. A pixel 2pt under each
    /// panel's bottom edge, on the window fill, must be darker than the same fill far from it, and only a shadow dropped
    /// downward is that dark there. Every layer that draws the raised shadow in its own bounds leaves room for its whole
    /// bleed, so no edge cuts it: the tracker plates' silhouette layers and the toast's hosting view.
    private static func testChromeShadowsReachPastTheirClips() throws {
        try expect(TrackerPlateDesign.silhouetteMargin >= Elevation.raised.bleed, "the plates' silhouette layers should hold the raised shadow's \(Elevation.raised.bleed) bleed, got a \(TrackerPlateDesign.silhouetteMargin) margin")
        try expect(ToastBanner.shadowMargin >= Elevation.raised.bleed, "the toast's hosting view should hold the raised shadow's \(Elevation.raised.bleed) bleed, got a \(ToastBanner.shadowMargin) margin")

        func darkness(_ view: NSView, size: CGSize, belowPanelAt probe: CGPoint) throws -> CGFloat {
            view.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: size, scale: 1)
            window.contentView = view
            window.show()
            defer { window.close() }
            func capture() -> CGFloat? {
                guard let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ) else {
                    return nil
                }
                bitmap.size = size
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let shadowed = bitmap.colorAt(x: Int(probe.x), y: Int(probe.y)),
                      let bare = bitmap.colorAt(x: 2, y: 2), bare.redComponent > 0 else {
                    return nil
                }
                return shadowed.redComponent / bare.redComponent
            }
            var darkness: CGFloat = .infinity
            try expect(waitUntil {
                guard let value = capture() else {
                    return false
                }
                darkness = value
                return value < 0.92
            }, "the panel shadow should render under its clipped edge")
            return darkness
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
                try expect(waitUntil { findKeyField(in: view) != nil }, "the title field should mount at \(scale)x")
                if focused {
                    guard let field = findKeyField(in: view) else {
                        throw TestFailure("no title text field")
                    }
                    field.focusEditorAtEnd()
                    try expect(waitUntil { field.currentEditor() != nil }, "the title field should become editable at \(scale)x")
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
                let fieldWidthBefore = findKeyField(in: row.view)?.frame.width
                row.model.label = "Paladin"
                try expect(waitUntil {
                    guard let fieldWidthBefore, let field = findKeyField(in: row.view) else {
                        return false
                    }
                    return abs(field.frame.width - fieldWidthBefore) > 0.5
                }, "the class segment should relayout the title field at \(scale)x")
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

    /// Edit Repo's Return saves the colour and closes, as Return submits in every other sheet. The colour is the sheet's
    /// only field, so the press reaches the sheet's keys with nothing of its own to take it first.
    private static func testEditRepoReturnSavesTheColour() throws {
        var saved: [String] = []
        var dismissals = 0
        let sheet = TrackerEditRepoSheet(
            repo: TrackerEditRepo(identity: "repo-1", name: "questmaster", color: "orange"),
            dismiss: { dismissals += 1 },
            save: { color in
                saved.append(color)
                return true
            }
        )
        let size = CGSize(width: 460, height: 260)
        let view = NSHostingView(rootView: sheet.frame(width: size.width, height: size.height))
        view.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size)
        window.contentView = view
        window.show(key: true)
        defer { window.close() }
        guard waitUntil({ sheetKeyMonitor(in: view) != nil }), let monitor = sheetKeyMonitor(in: view) else {
            throw TestFailure("the Edit Repo sheet should mount its key monitor")
        }
        try expect(monitor.onKeyDown(try keyEvent("\r", keyCode: 36)), "Return should be taken by the Edit Repo sheet")
        try expect(saved == ["orange"], "Return should save the repo's colour, got \(saved)")
        try expect(dismissals == 1, "saving with Return should close the sheet, got \(dismissals) dismissals")
    }

    /// The delete confirmation's Return confirms, through the shared modal keys rather than a SwiftUI default button,
    /// and ⌃[ cancels as Esc does.
    private static func testDeleteConfirmationReturnConfirmsAndControlBracketCancels() throws {
        var decisions: [Bool] = []
        let sheet = DestructiveConfirmationSheetView(spec: .deleteSession(sessionID: "qm-1"), onDecision: { decisions.append($0) })
        let size = CGSize(width: DestructiveConfirmationSheetView.width, height: 240)
        let view = NSHostingView(rootView: sheet)
        view.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size)
        window.contentView = view
        window.show(key: true)
        defer { window.close() }
        guard waitUntil({ sheetKeyMonitor(in: view) != nil }), let monitor = sheetKeyMonitor(in: view) else {
            throw TestFailure("the delete confirmation should mount its key monitor")
        }
        try expect(monitor.onKeyDown(try keyEvent("\r", keyCode: 36)), "Return should be taken by the delete confirmation")
        try expect(decisions == [true], "Return should confirm the delete, got \(decisions)")
        try expect(monitor.onKeyDown(try keyEvent("[", keyCode: 33, modifierFlags: [.control])), "⌃[ should be taken by the delete confirmation")
        try expect(decisions == [true, false], "⌃[ should cancel the delete, got \(decisions)")
    }

    private static func sheetKeyMonitor(in view: NSView) -> SheetKeyEventMonitor.MonitorView? {
        subviews(of: view).compactMap { $0 as? SheetKeyEventMonitor.MonitorView }.first
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
            try expect(waitUntil { editingField(in: view) != nil }, "the Edit Session title should begin editing at \(scale)x")
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
            try expect(waitUntil {
                guard let field = editingField(in: view) else {
                    return false
                }
                return before.width - field.frame.width > 5
            }, "⌃e should finish widening the class segment at \(scale)x")
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
                    try expect(waitUntil { findKeyField(in: view) != nil }, "the filter field should mount for \(name)")
                    if focused {
                        guard let field = findKeyField(in: view) else {
                            throw TestFailure("no filter text field")
                        }
                        field.focusEditorAtEnd()
                        try expect(waitUntil { field.currentEditor() != nil }, "the filter field should become editable for \(name)")
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
            try expect(waitUntil { fields(in: hosting).contains(where: \.isEditable) }, "\(name): an editable text field should mount")
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
        try check("Quest Log filter", QuestLogView(store: store, filter: QuestLogFilter(), layout: QuestLogLayout(sheetSize: QuestLogMetrics.sheetSize), onCommand: { _ in }), size: QuestLogMetrics.sheetSize)
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

        // The page's middle, in the host's coordinates: the 900 x 780 log is centred, its page 473 wide at (397, 40).
        let logOrigin = NSPoint(x: (1000 - 900) / 2, y: (860 - 780) / 2)
        let pageMiddle = NSPoint(x: logOrigin.x + 397 + 236, y: host.bounds.height - (logOrigin.y + 40 + 330))
        func pageHit() -> NSView? {
            host.hitTest(host.superview?.convert(pageMiddle, from: host) ?? pageMiddle)
        }
        func pageScrollView() -> NSScrollView? {
            guard let hit = pageHit() else {
                return nil
            }
            return hit as? NSScrollView ?? hit.enclosingScrollView
        }
        try expect(waitUntil {
            guard !hasAnimations(in: host.layer),
                  let scrollView = pageScrollView(),
                  let documentView = scrollView.documentView else {
                return false
            }
            return documentView.frame.height > scrollView.contentView.bounds.height && pageScroll.moreBelow
        }, "the Quest Log page should finish opening and lay out its overflowing scroll view before wheel input")
        guard let hit = pageHit() else {
            throw TestFailure("nothing under the page takes the wheel")
        }
        guard let scrollView = pageScrollView() else {
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
        try expect(waitUntil { scrollView.contentView.bounds.origin.y != before }, "the wheel should scroll the Quest Log page (offset stayed \(before))")

        // The page keys (PageDown and friends) go through the same scroller; past the end, the cue goes away.
        let afterWheel = scrollView.contentView.bounds.origin.y
        pageScroll.scroll(byPages: 0.5)
        try expect(waitUntil { scrollView.contentView.bounds.origin.y > afterWheel }, "a half-page key should scroll the Quest Log further down")
        pageScroll.scroll(byPages: 50)
        let maxOffset = documentHeight - scrollView.contentView.bounds.height
        try expect(waitUntil { abs(scrollView.contentView.bounds.origin.y - maxOffset) < 1 }, "scrolling past the end should stop at the bottom of the Quest Log")
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

        QuestLogDebug.parchmentDraws = 0
        store.open()
        stack.presentQuestLog(QuestLogModal(store: store, filter: QuestLogFilter(), pageScroll: QuestLogPageScroll(), onCommand: { _ in }))
        try expect(waitUntil { QuestLogDebug.parchmentDraws > 0 }, "opening should draw the Quest Log parchment")
        try waitForMainQueueTurn()
        try expect(!host.isHidden, "opening should show the Quest Log")
        try expect((1...2).contains(QuestLogDebug.parchmentDraws), "the parchment should draw once for the opening, not per unroll frame; drew \(QuestLogDebug.parchmentDraws) times")

        store.close()
        stack.dismiss(id: QuestLogModal.stackID)
        try expect(!host.isHidden, "the Quest Log should stay visible while it fades out")
        try expect(waitUntil { host.isHidden }, "the Quest Log host should hide when its fade-out finishes")
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
        try expect(commandModel.handleArtifactFilterCommand(.plain(48)), "Tab should accept the command suggestion")
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
            commandModel.handleArtifactFilterCommand(.plain(51)),
            "empty-tail Backspace should remove the previous token"
        )
        try expect(commandModel.artifactModel.artifacts == [report, screenshot], "Backspace should clear the last token filter")
        var leaves = 0
        commandModel.onArtifactFilterLeave = { leaves += 1 }
        commandModel.setArtifactFilterQuery("@")
        try expect(commandModel.handleArtifactFilterCommand(.plain(53)), "Esc should close visible suggestions")
        try expect(!commandModel.artifactModel.filterSuggestionsVisible, "Esc should hide suggestions")
        try expect(leaves == 0, "the Esc that hides suggestions should keep the keys in the filter")
        try expect(commandModel.handleArtifactFilterCommand(.plain(53)), "second Esc should be the filter's and hand the keys back")
        try expect(leaves == 1, "second Esc should hand the keys back to the list, got \(leaves)")

        commandModel.setArtifactFilterQuery("")
        let matches = commandModel.artifactModel.artifacts
        try expect(matches == [report, screenshot], "precondition: the project token leaves two rows")
        try expect(commandModel.handleArtifactFilterCommand(.plain(36)), "Return should be the filter's when no suggestion shows")
        try expect(commandModel.artifactModel.selectedArtifactID == matches[0].id, "Return should put the cursor on the first match")
        try expect(commandModel.handleArtifactFilterCommand(.plain(125)), "↓ should move the list when no suggestion shows")
        try expect(commandModel.artifactModel.selectedArtifactID == matches[1].id, "↓ should move the cursor to the next match")
        var opened: [String] = []
        commandModel.onOpenArtifactIntent = { opened.append($0) }
        try expect(commandModel.handleArtifactFilterCommand(.plain(36)), "Return should be the filter's again")
        try expect(commandModel.artifactModel.selectedArtifactID == matches[0].id && opened.isEmpty, "Return should go back to the first match and open nothing")
        try expect(leaves == 3, "each Return should hand the keys back to the list, got \(leaves)")

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
        let routes = try [100, 300, 200].map { value in
            try TmuxRoute(sessionID: "qm-\(value)", label: "default", configFiles: [], live: true, createdUnix: Int64(value))
        }
        try expect(TmuxRoute.startupChoice(preferred: "qm-100", routes: routes)?.sessionID == "qm-100", "remembered live route should win")
        try expect(TmuxRoute.startupChoice(preferred: "qm-999", routes: routes)?.sessionID == "qm-300", "stale preference should use newest route")
        try expect(TmuxRoute.startupChoice(preferred: nil, routes: routes)?.sessionID == "qm-300", "no preference should use newest route")
        try expect(TmuxRoute.startupChoice(preferred: "qm-100", routes: []) == nil, "no live routes should return nil")
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

    /// The ended-session icon means the viewed session is really gone: a delete of it that succeeded with nowhere to switch to.
    /// A plain mutation, a failed one and a delete that first switches to a recovery session (an attach, whose veil must show)
    /// never raise it; and the terminal pane's overlay is up only between `showEnded` and `clearEnded`.
    private static func testEndedIconShowsOnlyWhenTheViewedSessionIsGone() throws {
        func ended(_ result: Result<ServeMutationAck, Error>, request: ServeMutationRequest, switchTo: String? = nil, clear: Bool) throws -> (ended: Int, switches: Int) {
            let endedCount = Counter()
            let switches = Counter()
            let failures = Counter()
            var finished = false
            let coordinator = sessionCoordinator(client: StubMutationClient(result: result), failures: failures, switches: switches, ended: endedCount)
            coordinator.sendMutation(
                request,
                label: "delete",
                switchToSessionID: switchTo,
                switchBeforeMutation: switchTo != nil,
                clearTerminalOnSuccess: clear
            ) { finished = true }
            try waitForMainQueue("the mutation to settle", until: { finished || failures.value > 0 })
            try waitForMainQueueTurn()
            return (endedCount.value, switches.value)
        }
        let delete = try ServeMutationRequests.delete(sessionID: "qm-a")
        let ack = ServeMutationAck(data: nil)

        let gone = try ended(.success(ack), request: delete, clear: true)
        try expect(gone.ended == 1 && gone.switches == 0, "deleting the viewed session with nowhere to go shows the ended icon, with no attach")
        let recovered = try ended(.success(ack), request: delete, switchTo: "qm-b", clear: false)
        try expect(recovered.ended == 0 && recovered.switches == 1, "deleting it after switching to a recovery session attaches and never shows the icon")
        let other = try ended(.success(ack), request: delete, clear: false)
        try expect(other.ended == 0, "deleting some other session doesn't end the viewed one")
        let failed = try ended(.failure(StubMutationError()), request: delete, clear: true)
        try expect(failed.ended == 0, "a delete that failed hasn't ended anything")

        let shell = TerminalShellView(body: NSView())
        try expect(!shell.showsEnded, "a terminal pane starts with no ended icon: it is attaching or attached")
        shell.showEnded()
        try expect(shell.showsEnded, "showEnded puts the icon up")
        shell.clearEnded()
        try expect(!shell.showsEnded, "clearEnded, which every attach does, takes it off")
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
                } catch ServeClientError.protocolMismatch {
                    // Expected: the version mismatch wins over the response payload.
                }
            }
        }
        _ = try UnixSocketMutationClient.decodeAck(Data("{\"protocol_version\":3,\"type\":\"response\",\"ok\":true,\"data\":{}}".utf8))
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

        // The recovered line is padded past many 8 KiB reads, so the stream has to join it across reads.
        let padding = String(repeating: "x", count: 100_000)
        let lines = [
            "{\"protocol_version\":1,\"type\":\"event\",\"topic\":\"tracker\",\"data\":{\"observed_at\":\"wrong\",\"sessions\":[]}}\n",
            "{\"protocol_version\":3,\"type\":\"event\",\"topic\":\"tracker\",\"data\":{\"observed_at\":\"recovered\",\"sessions\":[],\"padding\":\"\(padding)\"}}\n",
        ]
        DispatchQueue.global().async {
            for line in lines {
                var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&ready, 1, 5_000) == 1 else { return }
                let peer = Darwin.accept(listener, nil, nil)
                guard peer >= 0 else { return }
                try? UnixSocketIO.setReadTimeout(on: peer, seconds: 5)
                let hello = "{\"root\":\"\(fixture.stateRoot.path)\",\"identity\":\"canonical\",\"protocol_version\":3,\"accepting\":true}\n"
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
        var states: [ConnectionState] = []
        let recordJSON: [String: Any] = [
            "running": true, "root": fixture.stateRoot.path, "identity": "canonical", "socket": path,
            "executable": fixture.qm.path, "shim_directory": fixture.root.appendingPathComponent("shim").path,
            "build": "test", "generation": 1, "accepting": true,
        ]
        let record = try JSONDecoder().decode(DaemonRecord.self, from: JSONSerialization.data(withJSONObject: recordJSON))
        let config = LaunchConfiguration.load(arguments: ["--no-daemon-start"], environment: fixture.environment,
                                              workingDirectory: fixture.workingDirectory.path, bundle: fixture.bundle)
        let client = UnixSocketServeClient(connection: DaemonConnection(config: config, record: record))
        defer { client.stop() }
        client.start(onUpdate: { update in
            DispatchQueue.main.async {
                labels.append(update.observedLabel ?? "")
                states.append(contentsOf: update.connection.map { [$0] } ?? [])
            }
        })
        try waitForMainQueue("protocol mismatch and recovered tracker stream", until: {
            states.contains(where: { $0.blockingMessage?.contains("protocol_version") == true }) && labels.contains("recovered")
        })
        try expect(!labels.contains("wrong"), "incompatible tracker data should not reach the store")
        let afterMismatch = states.drop(while: { $0.blockingMessage == nil })
        try expect(afterMismatch.contains(.connected), "the recovered tracker should make the connection live again, got \(states)")
    }

    private static func testReadLineReturnsALineSpanningManyReads() throws {
        var fds: [Int32] = [0, 0]
        try expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "could not create socket pair")
        defer {
            close(fds[0])
            close(fds[1])
        }
        let line = Data(String(repeating: "x", count: 600_000).utf8)
        let writer = fds[1]
        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? UnixSocketIO.write(line + Data("\nnext".utf8), to: writer)
            written.signal()
        }
        let read = try UnixSocketIO.readLine(from: fds[0])
        // The sockets close only once the writer is done, so it never writes to a closed one.
        try waitForSemaphore(written, description: "the large socket write")
        try expect(read == line, "readLine should return the whole line, newline and later bytes excluded (got \(read.count) bytes)")
    }

    /// A tracker line reaches the store only once its newline arrives, however the bytes are split across writes; a
    /// blank line is skipped and the connection stays up.
    private static func testServeStreamJoinsLinesSplitAcrossWrites() throws {
        let harness = try ServeStreamHarness()
        defer { harness.finish() }
        harness.start()
        let one = serveTrackerLine("wire-one")
        let two = serveTrackerLine("wire-two")
        let three = serveTrackerLine("wire-three", padding: 100_000)

        try harness.write(String(one.prefix(40)))
        try harness.waitForRead()
        try harness.write(String(one.dropFirst(40)) + "\n" + String(two.prefix(30)))
        try harness.waitForRead()
        try waitForMainQueue("the first line", until: { harness.wireLabels == ["wire-one"] })
        try expect(harness.wireLabels == ["wire-one"], "a line without its newline should wait, got \(harness.wireLabels)")

        try harness.write(String(two.dropFirst(30)) + "\n\n")
        try harness.waitForRead()
        let bytes = Array((three + "\n").utf8)
        for start in stride(from: 0, to: bytes.count, by: 1_000) {
            try UnixSocketIO.write(Data(bytes[start..<min(start + 1_000, bytes.count)]), to: harness.daemon)
        }
        try waitForMainQueue("every line", until: { harness.wireLabels.count == 3 })
        try expect(harness.wireLabels == ["wire-one", "wire-two", "wire-three"], "lines should arrive whole and in order, got \(harness.wireLabels)")
        try expect(harness.connects == 1, "a split line should not drop the connection, got \(harness.connects) connects")
    }

    /// A line as long as the pending-line cap still arrives; bytes past the cap with no newline drop the connection,
    /// nothing of that frame reaches the store, and the client connects again.
    private static func testServeStreamDropsAConnectionWhoseFrameOutgrowsTheCap() throws {
        let harness = try ServeStreamHarness()
        defer { harness.finish() }
        harness.start()
        let cap = UnixSocketServeClient.maxBufferedLineBytes
        let unpadded = serveTrackerLine("wire-at-cap")
        let atCap = serveTrackerLine("wire-at-cap", padding: cap - unpadded.utf8.count)
        try expect(atCap.utf8.count == cap, "the at-cap line should be exactly \(cap) bytes, got \(atCap.utf8.count)")
        let stream = Data((serveTrackerLine("wire-before") + "\n" + atCap + "\n").utf8) + Data(repeating: 0x78, count: cap + 16_384)
        let daemon = harness.daemon
        let written = DispatchSemaphore(value: 0)
        // The client hangs up partway through the oversized frame, so this write ends in an error the test expects.
        DispatchQueue.global().async {
            try? UnixSocketIO.write(stream, to: daemon)
            written.signal()
        }

        try expect(readsClosed(daemon), "the client should close a connection whose frame outgrows the cap")
        // The daemon end closes only once the writer is done with it.
        try waitForSemaphore(written, description: "the oversized socket write")
        try waitForMainQueue("a reconnect after the oversized frame", until: { harness.connects >= 2 })
        try waitForMainQueueTurn()
        try expect(harness.wireLabels == ["wire-before", "wire-at-cap"], "only the whole lines should arrive, got \(harness.wireLabels)")
    }

    /// A line with another protocol version ends the read: lines after it on the same connection never reach the store,
    /// and the client connects again.
    private static func testServeStreamStopsReadingAtAMidStreamProtocolMismatch() throws {
        let harness = try ServeStreamHarness()
        defer { harness.finish() }
        harness.start()
        let lines = [
            serveTrackerLine("wire-before"),
            serveTrackerLine("wire-mismatched", version: ServeContract.protocolVersion - 1),
            serveTrackerLine("wire-after"),
        ]
        try harness.write(lines.joined(separator: "\n") + "\n")

        try expect(readsClosed(harness.daemon), "the client should close the connection at the mismatched line")
        try waitForMainQueue("a reconnect after the mismatch", until: { harness.connects >= 2 })
        try waitForMainQueueTurn()
        try expect(harness.wireLabels == ["wire-before"], "nothing from the mismatched line on should arrive, got \(harness.wireLabels)")
    }

    /// A dropped connection (every daemon restart) keeps the last tracker in the store until a fresh one arrives,
    /// rather than emptying it.
    private static func testServeStreamKeepsTheLastTrackerWhenTheConnectionDrops() throws {
        let harness = try ServeStreamHarness()
        defer { harness.finish() }
        harness.start()
        let line = "{\"protocol_version\":\(ServeContract.protocolVersion),\"type\":\"event\",\"topic\":\"tracker\",\"data\":{\"observed_at\":\"wire-live\",\"sessions\":[{\"id\":\"qm-1\",\"title\":\"Kept\",\"status\":\"active\",\"state\":\"idle\",\"elapsed_ms\":0,\"worker_count\":0,\"repo\":{\"identity\":\"example-app\",\"name\":\"example-app\"}}]}}\n"
        try harness.write(line)
        try waitForMainQueue("the live tracker", until: { harness.wireLabels == ["wire-live"] })

        shutdown(harness.daemon, SHUT_RDWR)
        try waitForMainQueue("a reconnect after the drop", until: { harness.connects >= 2 })
        try waitForMainQueueTurn()
        let sessions = harness.store.snapshot.tracker.repos.flatMap(\.sessions).map(\.id)
        try expect(sessions == ["qm-1"], "the last tracker should stay after the drop, got \(sessions)")
        try expect(harness.store.snapshot.connection == .reconnecting, "the store should know the tracker is the last one, got \(harness.store.snapshot.connection)")
    }

    /// Stop ends a healthy connection at once: it returns without waiting, the socket closes, the loop exits and the
    /// client doesn't connect again.
    private static func testServeClientStopEndsAConnectedStream() throws {
        let harness = try ServeStreamHarness()
        defer { harness.finish() }
        harness.start()
        try harness.write(serveTrackerLine("wire-live") + "\n")
        try waitForMainQueue("the live line", until: { harness.wireLabels == ["wire-live"] })

        harness.client.stop()
        try expect(readsClosed(harness.daemon), "stop should close a connected socket at once")
        try expect(serveLoopExits(harness.client), "the loop should exit once stopped")
        try expect(harness.connects == 1, "a stopped client should not connect again, got \(harness.connects) connects")
    }

    /// A stop that lands while a connect is under way closes the socket that connect returns, without reading it.
    private static func testServeClientStopClosesASocketThatConnectsAfterIt() throws {
        var fds: [Int32] = [0, 0]
        try expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "could not create socket pair")
        defer { close(fds[1]) }
        let clientEnd = fds[0]
        let connecting = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let client = UnixSocketServeClient(connect: {
            connecting.signal()
            release.wait()
            return clientEnd
        }, invalidate: {})
        client.start(onUpdate: { _ in })
        try waitForSemaphore(connecting, description: "the blocked connect to begin")

        let stopReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            client.stop()
            stopReturned.signal()
        }
        try waitForSemaphore(stopReturned, description: "stop to return while connect remains blocked")
        release.signal()
        try expect(readsClosed(fds[1]), "a socket connected after stop should close at once")
        try expect(serveLoopExits(client), "the loop should exit once stopped")
    }

    /// Stop wakes the wait between failed connects instead of sleeping it out.
    private static func testServeClientStopEndsTheRetryWait() throws {
        let retryWaitStarted = DispatchSemaphore(value: 0)
        let client = UnixSocketServeClient(connect: {
            throw ServeClientError.connect("no daemon in this test")
        }, invalidate: {}, onRetryWait: { retryWaitStarted.signal() }, retryDelays: [60 * 60])
        client.start(onUpdate: { _ in })
        try waitForSemaphore(retryWaitStarted, description: "the client to enter its one-hour retry wait")

        client.stop()
        try expect(serveLoopExits(client), "stop should end the retry wait at once")
    }

    /// A write to a socket whose other end has gone (a daemon that hung up, or a stop's shutdown before the serve
    /// client's requests go out) fails with an error instead of raising SIGPIPE, which the app doesn't ignore.
    private static func testSocketWriteToAPeerThatHungUpFailsWithoutSIGPIPE() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("qm-pipe-\(UUID().uuidString.prefix(8)).sock").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try expect(listener >= 0, "could not create test socket")
        defer {
            close(listener)
            unlink(path)
        }
        let bound = try UnixSocketIO.withAddress(path) { address, length in
            Darwin.bind(listener, address, length)
        }
        try expect(bound == 0 && listen(listener, 1) == 0, "could not listen on test socket")

        let client = try UnixSocketIO.connect(path: path)
        defer { close(client) }
        let peer = Darwin.accept(listener, nil, nil)
        try expect(peer >= 0, "could not accept the test connection")
        close(peer)

        var failed = false
        while !failed {
            do { try UnixSocketIO.write(Data("{}\n".utf8), to: client) } catch { failed = true }
        }
        try expect(failed, "a write to a peer that hung up should fail")
    }

    /// A barrier queued behind the connection loop runs only after it returns.
    private static func serveLoopExits(_ client: UnixSocketServeClient) -> Bool {
        let exited = DispatchSemaphore(value: 0)
        client.queue.async { exited.signal() }
        return exited.wait(timeout: .now() + selfTestWaitTimeout) == .success
    }

    /// One serve tracker event line, without its newline, labelled by `observed_at` and padded by `padding` bytes.
    private static func serveTrackerLine(_ label: String, version: Int = ServeContract.protocolVersion, padding: Int = 0) -> String {
        let pad = String(repeating: "x", count: padding)
        return "{\"protocol_version\":\(version),\"type\":\"event\",\"topic\":\"tracker\",\"data\":{\"observed_at\":\"\(label)\",\"sessions\":[],\"padding\":\"\(pad)\"}}"
    }

    /// Reads `fd` until its peer closes. The self-test case watchdog catches a broken loop that never closes it.
    private static func readsClosed(_ fd: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&ready, 1, socketPollTimeoutMilliseconds)
            if result < 0 && errno == EINTR { continue }
            guard result == 1 else { return false }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 || (count < 0 && errno == ECONNRESET) { return true }
            if count < 0 && errno == EINTR { continue }
            if count < 0 { return false }
        }
    }

    /// A serve client whose first connect is one end of a socket pair; the test plays the daemon on the other end
    /// (`daemon`). Every later connect fails, so after a drop the client only retries.
    @MainActor
    private final class ServeStreamHarness {
        let daemon: Int32
        let client: UnixSocketServeClient
        private let counter: ConnectCounter
        private let reads: DispatchSemaphore
        /// The `observed_at` labels of the tracker updates that reached the client's callback, in order, on the main
        /// queue. Only `wire-` labels count: the client also reports its own connection status as updates.
        private(set) var wireLabels: [String] = []
        /// Every update applied in order, as the app's runtime connection applies them.
        let store = RuntimeStore(sourceLabel: "test")

        var connects: Int { counter.value }

        init() throws {
            var fds: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
                throw TestFailure("could not create socket pair")
            }
            var on: Int32 = 1
            for fd in fds {
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            }
            let clientEnd = fds[0]
            let counter = ConnectCounter()
            let reads = DispatchSemaphore(value: 0)
            daemon = fds[1]
            self.counter = counter
            self.reads = reads
            client = UnixSocketServeClient(connect: {
                guard counter.increment() == 1 else {
                    throw ServeClientError.connect("the test daemon accepts one connection")
                }
                return clientEnd
            }, invalidate: {}, onRead: { reads.signal() })
        }

        func start() {
            client.start(onUpdate: { [weak self] update in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.store.apply(update)
                    guard update.tracker != nil, let label = update.observedLabel, label.hasPrefix("wire-") else { return }
                    self.wireLabels.append(label)
                }
            })
        }

        func write(_ text: String) throws {
            try UnixSocketIO.write(Data(text.utf8), to: daemon)
        }

        func waitForRead() throws {
            try LogicSelfTests.waitForSemaphore(reads, description: "the client to read socket bytes")
        }

        func finish() {
            client.stop()
            close(daemon)
        }
    }

    private final class ConnectCounter {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }

        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            count += 1
            DispatchQueue.main.async {}
            return count
        }
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

    /// The portraits' bundle names are flattened (`class-<id>`, `familiar-<class-id>`, `random`): each resolves to its own raster,
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
                initialTypes: [],
                initialSize: "",
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
                initialTypes: [],
                initialSize: "",
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

    /// An Edit Quest sheet for quest qst-1 with the given types and size.
    private static func editQuestSheet(types: [String] = [], size: String = "") -> NewQuestSheetModel {
        NewQuestSheetModel(
            presentation: NewQuestSheetPresentation(
                projects: [NewQuestProjectOption(projectID: "/tmp/a/.git", projectPath: "/tmp/a", projectName: "a")],
                initialProject: NewQuestProjectOption(projectID: "/tmp/a/.git", projectPath: "/tmp/a", projectName: "a"),
                initialContent: "Quest",
                initialTypes: types,
                initialSize: size,
                questID: "qst-1",
                sessionID: "",
                mutationClient: StubMutationClient(result: .failure(StubMutationError())),
                directoryClient: nil,
                onSuccess: {}
            ),
            dismiss: {}
        )
    }

    /// The types field lists the open types as its suggestions and shows the chosen ones as chips, in their fixed order.
    private static func testEditQuestTypesFieldListsTheOpenTypesAsSuggestions() throws {
        let sheet = editQuestSheet(types: ["research", "bug"])
        try expect(sheet.tagSuggestions.map(\.title) == ["Improvement", "Feature", "Decision", "Cleanup"], "the open types should be the suggestions, in order")
        try expect(sheet.form.tags.tokens.map(\.title) == ["Bug", "Research"], "the chips should be the chosen types in their fixed order")
        sheet.form.tags.typeQuery("dec")
        try expect(sheet.highlightedTagSuggestionID == sheet.tagSuggestions.first?.id, "the best match should be the highlighted suggestion")
    }

    /// Tab moves the focus through the types, the size select, then the content, and the select takes the caret out of the text.
    private static func testEditQuestTabReachesTheSizeSelect() throws {
        let sheet = editQuestSheet()
        sheet.form.focusedField = .project
        try expect(sheet.handle(try keyEvent("", keyCode: 48)) && sheet.form.focusedField == .tags, "Tab should reach the types")
        let sinkBefore = sheet.sinkNonce
        try expect(sheet.handle(try keyEvent("", keyCode: 48)) && sheet.form.focusedField == .size, "Tab should reach the size")
        try expect(sheet.sinkNonce == sinkBefore + 1, "the size select should take the caret out of the text")
        try expect(sheet.handle(try keyEvent("", keyCode: 48)) && sheet.form.focusedField == .content, "Tab should reach the content")
    }

    /// The Size select steps with h/l and ←/→ (`ModalKeys`), ↑ does nothing, and a click steps it and keeps it focused.
    private static func testEditQuestSizeSelectCyclesWithHLAndArrows() throws {
        let sheet = editQuestSheet(size: "M")
        sheet.form.focusedField = .size
        try expect(sheet.handle(try keyEvent("h", keyCode: 4)) && sheet.form.size == .small, "h should step the size back")
        try expect(sheet.handle(try keyEvent("l", keyCode: 37)) && sheet.form.size == .medium, "l should step the size forward")
        try expect(sheet.handle(try keyEvent("", keyCode: 124)) && sheet.form.size == .large, "→ should step the size forward")
        try expect(sheet.handle(try keyEvent("", keyCode: 123)) && sheet.form.size == .medium, "← should step the size back")
        try expect(sheet.handle(try keyEvent("", keyCode: 126)) && sheet.form.size == .medium, "↑ should do nothing on the select")
        sheet.clickedSize()
        try expect(sheet.form.size == .large && sheet.form.focusedField == .size, "a click should step the size and keep the select focused")
    }

    /// An untouched size sends nothing; a step sends the new size, and a step back to none sends the empty value that clears it.
    private static func testEditQuestSizeIsSentOnlyWhenChanged() throws {
        let untouched = editQuestSheet(size: "M")
        try expect(untouched.form.submitPayload()?.size == nil, "an untouched size should send nothing")
        let stepped = editQuestSheet(size: "M")
        stepped.form.cycleSize(1)
        try expect(stepped.form.submitPayload()?.size == "L", "a changed size should be sent")
        let cleared = editQuestSheet(size: "M")
        cleared.form.cycleSize(1)
        cleared.form.cycleSize(1)
        try expect(cleared.form.submitPayload()?.size == "", "a size stepped back to none should send the empty value")
    }

    /// Return adds the highlighted type only while the typed query has a match.
    private static func testEditQuestTypesReturnAddsOnlyWhileTheQueryMatches() throws {
        let sheet = editQuestSheet()
        sheet.form.focusedField = .tags
        sheet.form.tags.typeQuery("bu")
        try expect(sheet.handle(try keyEvent("\r", keyCode: 36)) && sheet.form.tags.selectedTypes == [.bug], "Return should add the matching type")
        try expect(sheet.form.tags.query == "", "adding the type should clear the query")
    }

    /// Return with no query submits the sheet and adds no type, so a stray Return on the types field can't change it.
    private static func testEditQuestReturnWithNoQuerySubmits() throws {
        let sheet = editQuestSheet()
        sheet.form.focusedField = .tags
        try expect(sheet.handle(try keyEvent("\r", keyCode: 36)), "Return should be consumed by the submit")
        try expect(sheet.form.tags.selected.isEmpty, "Return with no query should add no type")
        try expect(sheet.form.submitting, "Return with no query should submit the form")
    }

    /// Space is taken and types nothing; Backspace in an empty query removes the last chip; e types, and leaves the size alone.
    private static func testEditQuestSpaceBackspaceAndETypeInTheTypesField() throws {
        let sheet = editQuestSheet(types: ["bug", "research"])
        sheet.form.focusedField = .tags
        try expect(sheet.handle(try keyEvent(" ", keyCode: 49)) && sheet.form.tags.selectedTypes == [.bug, .research], "Space should be taken and choose nothing")
        try expect(sheet.handle(try keyEvent("\u{7F}", keyCode: 51)) && sheet.form.tags.selectedTypes == [.bug], "Backspace in an empty query should remove the last chip")
        try expect(!sheet.handle(try keyEvent("e", keyCode: 14)) && sheet.form.size == nil, "e should type into the types field and leave the size alone")
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

    /// Tab takes the highlighted directory and closes the rows; the next Tab moves on. Tab never lists the
    /// directory's contents: typing does that (`testNewSessionTypingAfterATakeRefreshesTheRows`).
    private static func testNewSessionPathTabTakesTheRowAndDoesNotDrillDown() throws {
        let model = newSessionSheetModel(modelClient: nil, initialFocus: .path)
        model.state.paths.show(["/nonexistent-qm/a", "/nonexistent-qm/b"])
        model.state.paths.moveHighlight(1)
        try expect(model.handle(try keyEvent("\t", keyCode: 48)), "Tab should be consumed")
        try expect(model.state.model.path == "/nonexistent-qm/b", "Tab should take the highlighted directory")
        try expect(!model.state.showsPathSuggestions, "Tab should close the rows rather than list the directory's contents")
        try expect(model.state.model.focusedField == .path, "Tab should stay in the path")
        try expect(model.handle(try keyEvent("\t", keyCode: 48)), "the next Tab should be consumed")
        try expect(model.state.model.focusedField == .title, "the next Tab should move on: there is nothing to complete")
    }

    /// Return submits the sheet while rows show, unless ↑/↓ chose one: then it takes that row and stays.
    private static func testNewSessionPathReturnTakesARowOnlyOnceAnArrowChoseIt() throws {
        let typed = newSessionSheetModel(modelClient: nil, initialFocus: .path)
        typed.state.paths.show(["/nonexistent-qm/a", "/nonexistent-qm/b"])
        try expect(typed.handle(try keyEvent("\r", keyCode: 36)), "Return should be consumed by the submit")
        try expect(typed.state.model.path == "/tmp/project", "Return should keep the typed path while no arrow chose a row")
        try expect(typed.state.model.submitting, "Return should submit the sheet")

        let chosen = newSessionSheetModel(modelClient: nil, initialFocus: .path)
        chosen.state.paths.show(["/nonexistent-qm/a", "/nonexistent-qm/b"])
        try expect(chosen.handle(try keyEvent("", keyCode: 125)), "↓ should move in the rows")
        try expect(chosen.handle(try keyEvent("\r", keyCode: 36)), "Return should be consumed once ↓ chose a row")
        try expect(chosen.state.model.path == "/nonexistent-qm/b" && !chosen.state.showsPathSuggestions, "Return should take the chosen row and close the rows")
        try expect(!chosen.state.model.submitting, "taking a row should not submit")
    }

    /// ⌃n and ⌃p move the rows' highlight, as ↓ and ↑ do.
    private static func testNewSessionPathControlNAndControlPMoveTheRows() throws {
        let model = newSessionSheetModel(modelClient: nil, initialFocus: .path)
        model.state.paths.show(["/nonexistent-qm/a", "/nonexistent-qm/b"])
        try expect(model.handle(try keyEvent("n", keyCode: 45, modifierFlags: .control)), "⌃n should be consumed")
        try expect(model.state.paths.highlightedIndex == 1, "⌃n should move the highlight down")
        try expect(model.handle(try keyEvent("p", keyCode: 35, modifierFlags: .control)), "⌃p should be consumed")
        try expect(model.state.paths.highlightedIndex == 0, "⌃p should move the highlight up")
    }

    /// Typing after a take asks for the rows of the path as it now reads: that is how a `/` drills down.
    private static func testNewSessionTypingAfterATakeRefreshesTheRows() throws {
        let directories = StubDirectoryClient(suggestions: ["/nonexistent-qm/a/child"])
        let model = NewSessionSheetModel(
            presentation: NewSessionSheetPresentation(
                initialPath: "",
                initialTitle: "",
                initialPrompt: "",
                initialFocus: .path,
                mutationClient: StubMutationClient(result: .failure(StubMutationError())),
                directoryClient: directories,
                modelClient: nil,
                effortClient: nil,
                onSuccess: { _ in }
            ),
            dismiss: {}
        )
        model.state.paths.show(["/nonexistent-qm/a"])
        try expect(model.handle(try keyEvent("\t", keyCode: 48)), "Tab should take the row")
        try expect(!model.state.showsPathSuggestions, "precondition: the rows closed")
        // What the text field's binding does: it sets the path, then asks for its rows.
        model.state.model.path = "/nonexistent-qm/a/"
        model.pathChanged()
        try waitForMainQueue("the rows for the typed folder", until: { model.state.showsPathSuggestions })
        try expect(directories.queries.last == "/nonexistent-qm/a/", "typing should ask for the folder as it now reads")
        try expect(model.state.paths.items == ["/nonexistent-qm/a/child"], "the folder's contents should show")
    }

    /// Tab takes the highlighted directory and the search goes on, so typing still appends to the path.
    private static func testNewQuestPathTabTakesTheDirectoryAndTheSearchGoesOn() throws {
        let sheet = newQuestSheet()
        try expect(sheet.handle(try keyEvent("/", keyCode: 44)), "a / should start a path search")
        sheet.projectTyped("/nonexistent-qm")
        sheet.paths.show(["/nonexistent-qm/a", "/nonexistent-qm/b"])
        sheet.paths.moveHighlight(1)
        try expect(sheet.handle(try keyEvent("\t", keyCode: 48)), "Tab should be consumed")
        try expect(sheet.form.projectText == "/nonexistent-qm/b" && sheet.form.projectMode == .search, "Tab should take the directory and keep the search")
        try expect(!sheet.paths.isVisible, "Tab should close the rows")
        sheet.projectTyped(sheet.form.projectText + "/")
        try expect(sheet.form.projectMode == .search && sheet.form.projectText == "/nonexistent-qm/b/", "typing should go on at the end of the path")
    }

    /// Tab with no rows completes the typed path from disk, or moves on when there is nothing to complete.
    private static func testNewQuestPathTabMovesOnWhenNothingCompletes() throws {
        let sheet = newQuestSheet()
        try expect(sheet.handle(try keyEvent("/", keyCode: 44)), "a / should start a path search")
        sheet.projectTyped("/nonexistent-qm/zz")
        try expect(sheet.handle(try keyEvent("\t", keyCode: 48)), "Tab should be consumed")
        try expect(sheet.form.focusedField == .content, "Tab with nothing to complete should move on")
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
    /// R arranges, j moves the highlight, and J / K move the highlighted project, through the sheet's own key handling.
    private static func testTmuxSettingsRendersAtSheetSize() throws {
        let status = TmuxConfigStatus(
            config: "/tmp/example/tmux/questmaster.conf", enforced: "/tmp/example/tmux/enforced.questmaster.conf",
            effectiveLabel: "questmaster", running: true, startedUnix: 100, sessions: 1,
            editedSinceStart: true, enforcedPending: true, templateVersion: 1, builtinTemplateVersion: 3
        )
        let settings = settingsSheetModel(mutationClient: StubMutationClient(result: .success(ServeMutationAck(data: nil))))
        settings.tmux.details = TmuxSettingsModel(status: status)
        settings.selectSection(.tmux)
        let size = try fittingSize(of: SettingsSheetView(model: settings))
        try expect(size.width <= SettingsSheetModel.sheetSize.width && size.height <= SettingsSheetModel.sheetSize.height,
                   "tmux section should fit inside Settings, got \(size)")
    }

    private static func testSettingsArrangeMovesAProjectWithShiftJAndK() throws {
        let runtime = RuntimeStore(sourceLabel: "test")
        let projects = ["alpha", "beta", "gamma"].map { TrackerProject(id: "/p/\($0)", name: $0, path: "/p/\($0)") }
        runtime.apply(RuntimeUpdate(tracker: TrackerSnapshot(repos: [], projects: projects)))
        let model = SettingsSheetModel(
            presentation: SettingsSheetPresentation(
                mutationClient: StubMutationClient(result: .success(ServeMutationAck(data: nil))),
                modelClient: nil,
                effortClient: nil,
                runtime: runtime
            ),
            dismiss: {}
        )
        model.selectSection(.projects)
        func press(_ characters: String, ignoring: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) throws -> Bool {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode
            ) else {
                throw TestFailure("could not create \(characters) key event")
            }
            return model.handle(event)
        }
        try expect(try press("r", ignoring: "r", keyCode: 15), "r should be taken")
        try expect(model.projects.isArranging, "r should start arranging")
        try expect(try press("j", ignoring: "j", keyCode: 38), "j should be taken")
        try expect(model.projects.highlightIndex == 1, "j should move the highlight to beta, got \(model.projects.highlightIndex)")
        try expect(try press("J", ignoring: "J", keyCode: 38, flags: .shift), "J should be taken")
        try expect(model.projects.projectRows.map(\.name) == ["alpha", "gamma", "beta"], "J should move beta down, got \(model.projects.projectRows.map(\.name))")
        try expect(try press("K", ignoring: "K", keyCode: 40, flags: .shift), "K should be taken")
        try expect(model.projects.projectRows.map(\.name) == ["alpha", "beta", "gamma"], "K should move beta back up, got \(model.projects.projectRows.map(\.name))")
    }

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

    /// The split view lays the header out over the terminal column: its top level with the tracker's and the dock's, the
    /// terminal starting the flush gap under it. Its empty space moves the window; a button keeps its click.
    private static func testActionBarHeaderSitsOverTheTerminalColumn() throws {
        let size = CGSize(width: 1400, height: 900)
        let window = HeadlessWindow(size: size)
        let splitView = MainSplitView(frame: NSRect(origin: .zero, size: size))
        let panes = (0..<3).map { _ in NSView() }
        panes.forEach(splitView.addArrangedSubview)
        let header = ActionBarShellView()
        splitView.setHeader(header)
        splitView.setDockVisible(true, animated: false)
        window.contentView = splitView
        window.show()
        defer { window.close() }
        splitView.applyCanonicalLayout()
        header.layoutSubtreeIfNeeded()

        let (tracker, terminal, dock) = (panes[0].frame, panes[1].frame, panes[2].frame)
        try expect(header.frame.height == ActionBarMetrics.height, "the header is \(ActionBarMetrics.height) high, got \(header.frame.height)")
        try expect(header.frame.maxY == tracker.maxY && header.frame.maxY == dock.maxY, "the header's top is level with the tracker's and the dock's")
        try expect(header.frame.minY - terminal.maxY == ShellMetrics.verticalFlushGap, "the terminal starts the flush gap under the header, got \(header.frame.minY - terminal.maxY)")
        try expect(dock.minX - header.frame.maxX == ShellMetrics.gap, "the header stops the shell gap short of the dock, got \(dock.minX - header.frame.maxX)")

        let middle = NSPoint(x: header.frame.midX, y: header.frame.midY)
        guard let empty = splitView.hitTest(middle) else {
            throw TestFailure("the header's empty space should take a click")
        }
        try expect(!(empty is NSHostingView<ActionBarView>) && empty.mouseDownCanMoveWindow, "the header's empty space moves the window, got \(empty)")
        let trackerToggle = NSPoint(x: header.frame.minX + ActionBarMetrics.endInset + ActionBarMetrics.buttonSize / 2, y: header.frame.midY)
        try expect(splitView.hitTest(trackerToggle) is NSHostingView<ActionBarView>, "a button keeps its click, got \(String(describing: splitView.hitTest(trackerToggle)))")
    }

    /// Caffeinate's on state is the tracker's working spinner round the button's border, there only while it is on.
    private static func testActionBarCaffeinateSpinsOnlyWhileOn() throws {
        let size = CGSize(width: 700, height: ActionBarMetrics.height)
        let window = HeadlessWindow(size: size)
        let header = ActionBarShellView()
        header.frame = NSRect(origin: .zero, size: size)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.addSubview(header)
        window.contentView = container
        window.show()
        defer { window.close() }
        func spinner() -> SpinnerRingNSView? {
            header.layoutSubtreeIfNeeded()
            return descendant(SpinnerRingNSView.self, in: header)
        }

        try waitForMainQueue("the bar to draw") {
            header.layoutSubtreeIfNeeded()
            return descendant(NSHostingView<ActionBarView>.self, in: header) != nil
        }
        try expect(spinner() == nil, "no spinner while caffeinate is off")
        header.updateCaffeine(true)
        try waitForMainQueue("the spinner to appear") { spinner() != nil }
        guard let ring = spinner() else {
            throw TestFailure("the spinner should stay while caffeinate is on")
        }
        try expect(ring.frame.size == CGSize(width: ActionBarMetrics.buttonSize, height: ActionBarMetrics.buttonSize), "it traces the button's border, got \(ring.frame.size)")
        header.updateCaffeine(false)
        try waitForMainQueue("the spinner to go") { spinner() == nil }
    }

    /// The header sits under the window's transparent titlebar (`fullSizeContentView`), whose safe area would push
    /// SwiftUI content down: the buttons must stay centred, `ActionBarMetrics.buttonInset` from its top and bottom. The
    /// headless window has no titlebar, so this one is a titled window like the app's, never shown.
    private static func testActionBarButtonsCentreUnderTheTitlebar() throws {
        let size = CGSize(width: 700, height: 200)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = container
        let header = ActionBarShellView()
        header.frame = NSRect(x: 0, y: size.height - ShellMetrics.gap - ActionBarMetrics.height, width: size.width, height: ActionBarMetrics.height)
        container.addSubview(header)
        header.updateCaffeine(true)
        func ring() -> SpinnerRingNSView? {
            header.layoutSubtreeIfNeeded()
            return descendant(SpinnerRingNSView.self, in: header)
        }

        try waitForMainQueue("caffeinate's spinner to draw") { ring() != nil }
        guard let ring = ring() else {
            throw TestFailure("caffeinate's spinner should draw")
        }
        let button = ring.convert(ring.bounds, to: header)
        try expect(
            header.bounds.maxY - button.maxY == ActionBarMetrics.buttonInset && button.minY == ActionBarMetrics.buttonInset,
            "the buttons sit \(ActionBarMetrics.buttonInset) from the header's top and bottom under a titlebar, got top \(header.bounds.maxY - button.maxY), bottom \(button.minY)"
        )
    }

    /// The spinner turns its arc, not its ring: a rounded square (an action-bar toggle's border) must stay put while the
    /// arc runs round it, so the turn is on the gradient under a still mask, never on the masked layer.
    private static func testSpinnerTurnsItsArcUnderAStillRing() throws {
        let side = ActionBarMetrics.buttonSize
        let spinner = SpinnerRing()
        let square = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: side - 1, height: side - 1), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        spinner.layout(around: CGPoint(x: side / 2, y: side / 2), side: side, ringPath: square, lineWidth: 1)
        spinner.startSpinning()
        try expect(spinner.spinAnimation != nil, "the arc turns")
        try expect(spinner.layer.mask != nil && (spinner.layer.animationKeys() ?? []).isEmpty, "the masked layer, and so the ring, stays still")
        try expect(spinner.layers.allSatisfy { $0.mask == nil || $0 === spinner.layer }, "only the still layer carries the ring's mask")
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
        try waitForMainQueueTurn()

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
        try waitForMainQueueTurn()

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

    private static func pumpOneMainRunLoopTurn() throws {
        // Queue a real main-thread event so absence checks observe one complete turn.
        try waitForMainQueueTurn()
    }

    private static func waitForSemaphore(_ semaphore: DispatchSemaphore, description: String) throws {
        guard semaphore.wait(timeout: .now() + selfTestWaitTimeout) == .success else {
            throw TestFailure("timed out after \(selfTestWaitTimeout)s waiting for \(description)")
        }
    }

    /// Stops or restarts the clock for `view`'s layer tree. While it is stopped, a glide or fade holds its start
    /// for as long as the run loop runs, so a check never races an animation that has run out on a slow host.
    /// Restarting the clock runs the held animations from where they stopped.
    private static func holdMotion(_ view: NSView, _ held: Bool) {
        view.layer?.speed = held ? 0 : 1
    }

    /// Pumps the run loop until `condition` holds; the per-case watchdog bounds a broken wait.
    /// `f` opens the filter while the dock shows the worker log, j/k and Space then work its rows instead of scrolling
    /// the feed, and Esc, losing the keys or leaving the worker log close it.
    private static func testDockPaneRoutesTheWorkerLogFilterKeys() throws {
        let chat = WorkerChatStore()
        let sessions = [
            TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master"),
            TrackerSession(id: "w1", title: "One", repoName: "Repo", agent: "codex", role: "worker", parentID: "m"),
            TrackerSession(id: "w2", title: "Two", repoName: "Repo", agent: "claude", role: "worker", parentID: "m"),
        ]
        _ = chat.sync(selectedSessionID: "m", sessions: sessions, isVisible: true)
        let dock = SwiftUIDockPane(store: RuntimeStore(sourceLabel: "test"), workerChatStore: chat, newQuestPresenter: NewQuestSheetPresenter(), settingsPresenter: SettingsSheetPresenter())
        let snapshot = RuntimeSnapshot.empty(sourceLabel: "test")
        dock.apply(DockState(bottomVisible: true, dockContent: .workerChat), snapshot: snapshot)

        try dock.keyDown(with: keyEvent("j", keyCode: 38))
        try expect(!chat.menu.isOpen && chat.menu.cursor == 0, "j scrolls the feed while the filter is closed")
        try dock.keyDown(with: keyEvent("f", keyCode: 3))
        try expect(chat.menu.isOpen, "f should open the filter")
        try dock.keyDown(with: keyEvent("j", keyCode: 38))
        try expect(chat.menu.cursor == 1, "j should move the cursor, got \(chat.menu.cursor)")
        try dock.keyDown(with: keyEvent(" ", keyCode: 49))
        try expect(chat.filter.actions == [.item], "Space should toggle the row under the cursor, got \(chat.filter.actions)")
        try dock.keyDown(with: keyEvent("k", keyCode: 40, modifierFlags: .control))
        try expect(chat.menu.cursor == 1, "a ⌃ chord is not the filter's")
        try dock.keyDown(with: keyEvent("\u{1b}", keyCode: 53))
        try expect(!chat.menu.isOpen && chat.filter.actions == [.item], "Esc should close the filter and keep what it selected")

        // [ and ] step the worker tabs, All first, with the dropdown closed or open.
        try dock.keyDown(with: keyEvent("]", keyCode: 30))
        try expect(chat.filter.workerID == "w1", "] should select the first worker's tab, got \(String(describing: chat.filter.workerID))")
        try dock.keyDown(with: keyEvent("]", keyCode: 30))
        try dock.keyDown(with: keyEvent("]", keyCode: 30))
        try expect(chat.filter.workerID == nil, "] past the last tab should wrap to All, got \(String(describing: chat.filter.workerID))")
        try dock.keyDown(with: keyEvent("[", keyCode: 33))
        try expect(chat.filter.workerID == "w2", "[ from All should wrap to the last tab, got \(String(describing: chat.filter.workerID))")
        try dock.keyDown(with: keyEvent("]", keyCode: 30, modifierFlags: .command))
        try expect(chat.filter.workerID == "w2", "a ⌘ chord is not the tabs'")
        try dock.keyDown(with: keyEvent("f", keyCode: 3))
        try dock.keyDown(with: keyEvent("[", keyCode: 33))
        try expect(chat.filter.workerID == "w1" && chat.menu.isOpen, "[ should step the tabs with the dropdown open, and leave it open")
        try dock.keyDown(with: keyEvent("\u{1b}", keyCode: 53))

        try dock.keyDown(with: keyEvent("f", keyCode: 3))
        dock.setFocused(false)
        try expect(!chat.menu.isOpen, "losing the keys should close the filter")
        try dock.keyDown(with: keyEvent("f", keyCode: 3))
        dock.apply(DockState(bottomVisible: true, dockContent: .artifactList), snapshot: snapshot)
        try expect(!chat.menu.isOpen, "leaving the worker log should close the filter")
        try dock.keyDown(with: keyEvent("f", keyCode: 3))
        try expect(!chat.menu.isOpen, "f is the filter's only on the worker log")
        try dock.keyDown(with: keyEvent("]", keyCode: 30))
        try expect(chat.filter.workerID == "w1", "] is the tabs' only on the worker log")
    }

    /// The filter keeps the sizes measured from its designs on the 5pt rhythm: the dropdown's rows are 30 high under a header
    /// on the same band, and a chip is 25 high.
    private static func testWorkerLogFilterKeepsItsDesignedSize() throws {
        let panel = WorkerLogFilterPanel(filter: WorkerLogFilter(), cursor: 0, onToggle: { _ in })
        let panelSize = try fittingSize(of: panel)
        let bands = CGFloat(WorkerLogAction.allCases.count + 1)
        // The `Space.item` under the last row, and the outline's two edges.
        let chrome = Space.item + 2 * Token.Size.divider
        try expect(panelSize.height == bands * WorkerLogFilterMetrics.rowHeight + chrome, "the dropdown's height should be its header and rows on the scale, got \(panelSize.height)")

        let chipRow = WorkerLogChipRow(summary: "Status", onClear: {})
        let chipSize = try fittingSize(of: chipRow.frame(width: DockWidthPreference.panelWidth))
        try expect(chipSize.height == Space.row + ControlHeight.compact, "a chip row should be 5 over a 25-high chip, got \(chipSize.height)")
    }

    /// A click on the dock's top bar that isn't on a button (blank space, the title) ends the filter's dropdown, as one on
    /// the feed does. The filter icon only toggles, once; the x only closes the dock. Through the real `DockShellView`, so
    /// its top bar's hosting view and wiring are what is clicked.
    private static func testDockTopBarClicksEndTheLogFilterExceptOnItsOwnButtons() throws {
        var toggles = 0, dismissals = 0, hides = 0
        let model = DockChromeModel(topBar: .make(mode: .workerChat, artifactRoute: .list, artifactTitle: nil, logAttached: true))
        let dock = DockShellView(body: NSView(), model: model)
        dock.onToggleLogFilter = { toggles += 1 }
        dock.onDismissLogFilter = { dismissals += 1 }
        dock.onHideDock = { hides += 1 }
        let size = CGSize(width: DockWidthPreference.panelWidth, height: 300)
        let window = HeadlessWindow(size: size)
        dock.frame = NSRect(origin: .zero, size: size)
        window.contentView = dock
        window.show(key: true)
        defer { window.close() }
        try pumpOneMainRunLoopTurn()
        // Window coordinates run up from the bottom; the icons sit `dockTopBarIconCentre` down, the x 30 in from the right
        // edge less its half width.
        let iconY = size.height - ShellMetrics.dockTopBarIconCentre
        let closeX = size.width - ShellMetrics.dockTopBarHorizontalInset - ChromeMetrics.iconWidth / 2
        let filterX = closeX - ChromeMetrics.iconWidth - Space.item
        let blankY = size.height - ShellMetrics.dockTopBarHeight / 2
        func click(_ x: CGFloat, _ y: CGFloat) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    throw TestFailure("could not create a mouse event")
                }
                window.sendEvent(event)
                try pumpOneMainRunLoopTurn()
            }
        }
        try click(filterX, iconY)
        try expect(toggles == 1 && dismissals == 0 && hides == 0, "the filter icon should toggle once and not also dismiss, got \(toggles) toggles, \(dismissals) dismissals, \(hides) hides")
        try click(100, blankY)
        try expect(toggles == 1 && dismissals == 1 && hides == 0, "blank top-bar space should dismiss, got \(toggles) toggles, \(dismissals) dismissals, \(hides) hides")
        try click(size.width / 2, blankY)
        try expect(dismissals == 2 && toggles == 1, "the title should dismiss too, got \(dismissals) dismissals, \(toggles) toggles")
        try click(closeX, iconY)
        try expect(hides == 1 && dismissals == 2 && toggles == 1, "the x should only close the dock, got \(hides) hides, \(dismissals) dismissals, \(toggles) toggles")
    }

    /// With room for its rows the dropdown has no scroll view; with less it is exactly `maxHeight` high, scrolls, and has
    /// the cursor's row in view, here the last one.
    private static func testWorkerLogFilterScrollsPastItsMaxHeightAndKeepsTheCursorInView() throws {
        func panel(cursor: Int, maxHeight: CGFloat) -> some View {
            WorkerLogFilterPanel(filter: WorkerLogFilter(), cursor: cursor, maxHeight: maxHeight, onToggle: { _ in })
                .frame(width: 400, height: 700, alignment: .topTrailing)
        }
        let fits = NSHostingView(rootView: panel(cursor: 0, maxHeight: 400))
        let window = HeadlessWindow(size: CGSize(width: 400, height: 700))
        window.contentView = fits
        window.show()
        defer { window.close() }
        try pumpOneMainRunLoopTurn()
        try expect(descendant(NSScrollView.self, in: fits) == nil, "a dropdown with room for its rows should not scroll")

        let cap: CGFloat = 120
        let rowCount = WorkerLogAction.allCases.count
        let hosting = NSHostingView(rootView: panel(cursor: rowCount - 1, maxHeight: cap))
        let tall = HeadlessWindow(size: CGSize(width: 400, height: 700))
        tall.contentView = hosting
        tall.show()
        defer { tall.close() }
        try expect(waitUntil { descendant(NSScrollView.self, in: hosting) != nil }, "a dropdown taller than its cap should scroll")
        guard let scrollView = descendant(NSScrollView.self, in: hosting), let documentView = scrollView.documentView else {
            throw TestFailure("the dropdown should host a scroll view with a document")
        }
        let height = scrollView.convert(scrollView.bounds, to: hosting).height
        try expect(abs(height - (cap - 2 * Token.Size.divider)) <= 1, "the rows should fill the cap inside the outline, got \(height)")
        let clip = scrollView.contentView
        try expect(waitUntil { clip.bounds.origin.y > 0 }, "the cursor on the last row should scroll it into view")
        try expect(clip.bounds.maxY >= documentView.bounds.height - 1, "the last row should sit at the bottom of the rows, got \(clip.bounds.maxY) of \(documentView.bounds.height)")
    }

    /// The split dock with both panels showing: Watcher over the Worker Log, which is attached to a master with
    /// `workers` workers. The caller closes `window`.
    private static func splitWorkerLogDock(workers: Int, height: CGFloat = 860) -> (window: HeadlessWindow, column: DockColumnView, pane: SwiftUIDockPane, chat: WorkerChatStore, coordinator: ShellFocusCoordinator) {
        let chat = WorkerChatStore()
        let sessions = [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")]
            + (1...workers).map { TrackerSession(id: "w\($0)", title: "Worker \($0)", repoName: "Repo", agent: "codex", role: "worker", parentID: "m") }
        _ = chat.sync(selectedSessionID: "m", sessions: sessions, isVisible: true)
        let pane = SwiftUIDockPane(
            store: RuntimeStore(sourceLabel: "test"),
            workerChatStore: chat,
            newQuestPresenter: NewQuestSheetPresenter(),
            settingsPresenter: SettingsSheetPresenter()
        )
        pane.apply(DockState(bottomVisible: true, dockContent: .workerChat), snapshot: RuntimeSnapshot.empty(sourceLabel: "test"))
        let watcher = WatcherDockPane(store: PullRequestStore())
        let top = DockShellView(body: watcher, model: DockChromeModel(topBar: .watcher))
        let bottom = DockShellView(
            body: pane,
            model: DockChromeModel(topBar: .make(mode: .workerChat, artifactRoute: .list, artifactTitle: nil, logAttached: true))
        )
        let column = DockColumnView(top: top, bottom: bottom)
        let width = DockWidthPreference.panelWidth
        column.frame = NSRect(x: 0, y: 0, width: width, height: height)
        column.setPanels(DockPanels(top: true, bottom: true))
        let window = HeadlessWindow(size: CGSize(width: width, height: height))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.addSubview(column)
        window.contentView = content
        let coordinator = ShellFocusCoordinator(
            navigation: NavigationStore(),
            window: { window },
            splitView: { nil },
            terminalShell: { nil },
            topDockShell: { top },
            bottomDockShell: { bottom },
            dockColumn: { column },
            dockPanels: { DockPanels(top: true, bottom: true) },
            actionBar: { nil },
            trackerHosting: { nil },
            dockView: { pane },
            watcherPane: { watcher },
            terminalHost: { nil },
            modalHost: { nil },
            updateDockTabs: {}
        )
        window.show(key: true)
        column.layoutSubtreeIfNeeded()
        return (window, column, pane, chat, coordinator)
    }

    /// In the split dock the filter belongs to the bottom panel: `f` opens it while that panel has the keys, the keys
    /// moving to Watcher close it, and while they are there `f` is not the filter's.
    private static func testWorkerLogFilterFollowsTheBottomPanelsKeys() throws {
        let dock = splitWorkerLogDock(workers: 2)
        defer { dock.window.close() }
        dock.coordinator.focusDockPanel(.bottom)
        let opened = try dock.pane.performKeyEquivalent(with: keyEvent("f", keyCode: 3))
        try expect(opened && dock.chat.menu.isOpen, "f should open the filter while the bottom panel has the keys")
        dock.coordinator.focusDockPanel(.top)
        try expect(!dock.chat.menu.isOpen, "the keys moving to Watcher should close the filter")
        let stolen = try dock.pane.performKeyEquivalent(with: keyEvent("f", keyCode: 3))
        try expect(!stolen && !dock.chat.menu.isOpen, "f should not open the filter while Watcher has the keys")
    }

    /// Under Watcher, in a window short enough that the bottom panel can't hold all the rows, the dropdown scrolls
    /// inside what it has: 5 under the top bar and 20 above the panel's edge, never reaching behind Watcher.
    private static func testWorkerLogFilterStaysInsideTheBottomPanelBelowWatcher() throws {
        let dock = splitWorkerLogDock(workers: 2, height: 560)
        defer { dock.window.close() }
        dock.coordinator.focusDockPanel(.bottom)
        _ = dock.chat.handle(.toggleMenu)
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        // The feed scrolls too: the dropdown is the narrow one.
        func dropdown() -> NSScrollView? {
            scrollViews(in: dock.pane).first { $0.convert($0.bounds, to: dock.pane).width < dock.pane.bounds.width / 2 }
        }
        try expect(waitUntil { dropdown() != nil }, "the dropdown should scroll under Watcher, with its rows in the room left")
        guard let list = dropdown() else {
            throw TestFailure("the dropdown should host a scroll view")
        }
        let paneFrame = dock.column.convert(dock.pane.bounds, from: dock.pane)
        let listFrame = dock.column.convert(list.bounds, from: list)
        let topGap = paneFrame.maxY - listFrame.maxY
        let bottomGap = listFrame.minY - paneFrame.minY
        try expect(topGap >= Space.row, "the dropdown should hang 5 under the top bar, got \(topGap)")
        try expect(bottomGap >= Space.section, "the dropdown should stop 20 above the panel's edge, got \(bottomGap)")
    }

    /// The chip row sits under the top bar whatever is under it: with the first read pending, partial or failed nothing
    /// under the chips is greedy, and a stack that wraps its content would centre them in the dock.
    private static func testWorkerLogChipsStayUnderTheTopBarInEveryState() throws {
        let entry = WorkerFeedEntry(timestamp: "2026-10-07T00:00:00.000Z", workerID: "w1", workerTitle: "Worker 1", kind: "action", text: "Bash")
        let states: [(label: String, payload: WorkerFeedPayload?)] = [
            ("a pending first read", nil),
            ("a partial read", WorkerFeedPayload(hasMore: ["w1": true])),
            ("a failed read", WorkerFeedPayload(errors: ["w1": "unreadable"])),
            ("a known empty feed", WorkerFeedPayload()),
            ("a feed with lines", WorkerFeedPayload(entries: [entry])),
        ]
        var pendingTop: CGFloat?
        for (label, payload) in states {
            let chat = WorkerChatStore()
            let sessions = [
                TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master"),
                TrackerSession(id: "w1", title: "Worker 1", repoName: "Repo", agent: "codex", role: "worker", parentID: "m"),
            ]
            let request = chat.sync(selectedSessionID: "m", sessions: sessions, isVisible: true)
            chat.toggleAction(at: 0)
            if let payload, let request {
                _ = chat.receive(payload, for: request)
            }
            let size = CGSize(width: DockWidthPreference.panelWidth, height: 400)
            // The panel fill covers the whole view, so a dock that shrinks to its content shows as chips floating in it.
            let hosting = NSHostingView(rootView: WorkerChatDockView(store: chat, areaFocused: true).frame(maxWidth: .infinity, maxHeight: .infinity).background(AppPalette.panel.swiftUI))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: size)
            window.contentView = hosting
            window.show()
            defer { window.close() }
            try pumpOneMainRunLoopTurn()
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try snapshot(hosting, size: size, scale: 2)
            // The chip's label starts 10 in from the row's 20 inset.
            guard let edges = inkEdges(bitmap, scale: 2, columns: 30..<80, rows: 0..<Int(size.height), over: AppPalette.panel) else {
                throw TestFailure("the chips should draw in \(label)")
            }
            try expect(edges.top < ControlHeight.compact + Space.row, "the chips should sit under the top bar in \(label), got y \(edges.top)")
            if let pendingTop {
                try expect(abs(edges.top - pendingTop) < 0.5, "the chips should sit where they do with the read pending in \(label): \(pendingTop), got \(edges.top)")
            }
            pendingTop = pendingTop ?? edges.top
        }
    }

    /// The lines scrolled up under the header fade in over the feed's top `topFadeHeight`, from nothing at its edge, instead
    /// of being cut there. Solid blocks make each ink row's coverage the mask's alpha.
    private static func testWorkerChatFeedFadesInUnderItsHeader() throws {
        let lines = (0..<40).map { index in
            WorkerChatLine(id: "e\(index)", time: "09:00", agent: "claude", segments: [WorkerChatSegment(String(repeating: "\u{2588}", count: 12), .normal)])
        }
        let size = CGSize(width: 300, height: 200)
        let hosting = NSHostingView(rootView: WorkerChatFeedView(lines: lines, revision: 1, trimCount: 0, appended: false)
            .frame(width: size.width, height: size.height)
            .background(AppPalette.panel.swiftUI))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size)
        window.contentView = hosting
        window.show()
        defer { window.close() }
        try pumpOneMainRunLoopTurn()
        hosting.layoutSubtreeIfNeeded()
        guard let scrollView = descendant(NSScrollView.self, in: hosting) else {
            throw TestFailure("the feed should scroll")
        }
        // Row 10's ink starts 8 below the feed's top edge, inside the fade.
        let linePitch = WorkerChatMetrics.lineHeight + WorkerChatMetrics.itemGap
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: WorkerChatMetrics.inset + 10 * linePitch - 8))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try pumpOneMainRunLoopTurn()
        let bitmap = try snapshot(hosting, size: size, scale: 2)
        guard let base = AppPalette.panel.usingColorSpace(.deviceRGB) else {
            throw TestFailure("the panel colour should convert")
        }
        // The blocks' columns, clear of the time and the logo.
        func difference(atRow row: Int) -> CGFloat {
            (180..<260).map { x in
                guard let pixel = bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB) else {
                    return 0
                }
                return abs(pixel.redComponent - base.redComponent) + abs(pixel.greenComponent - base.greenComponent)
                    + abs(pixel.blueComponent - base.blueComponent)
            }.max() ?? 0
        }
        let fade = Int(WorkerChatMetrics.topFadeHeight * 2)
        let full = (fade + 20..<fade + 60).map(difference).max() ?? 0
        try expect(full > 0.3, "the feed's lines should show in full below the fade, got \(full)")
        let coverage = (0..<fade).map { difference(atRow: $0) / full }
        try expect(coverage.contains { $0 > 0.2 }, "a line should sit under the fade for the check to mean anything")
        for (row, value) in coverage.enumerated() {
            let allowed = (CGFloat(row) + 1) / CGFloat(fade) + 0.1
            try expect(value <= allowed, "ink at y \(CGFloat(row) / 2) should be at most \(allowed) of full under the fade, got \(value)")
        }
    }

    /// `view` as it draws on the panel colour in a headless window, at `scale`: the bitmap the colour tests sample.
    private static func drawnBitmap<V: View>(_ view: V, size: CGSize, scale: CGFloat) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height, alignment: .topLeading).background(AppPalette.panel.swiftUI)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size)
        window.contentView = hosting
        window.show()
        defer { window.close() }
        try pumpOneMainRunLoopTurn()
        hosting.layoutSubtreeIfNeeded()
        return try snapshot(hosting, size: size, scale: scale)
    }

    /// The brightest pixel in the points `columns`: the glyphs' fullest ink.
    private static func brightestInk(_ bitmap: NSBitmapImageRep, scale: CGFloat, columns: Range<CGFloat>) -> NSColor? {
        var best: (sum: CGFloat, color: NSColor)?
        for x in Int(columns.lowerBound * scale)..<Int(columns.upperBound * scale) {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let sum = color.redComponent + color.greenComponent + color.blueComponent
                if sum > (best?.sum ?? 0) {
                    best = (sum, color)
                }
            }
        }
        return best?.color
    }

    /// The sampled ink is nearer `expected` than `other`. A regular stroke in a fallback font doesn't always reach its
    /// colour (CI doesn't install JetBrains Mono), but the two text colours are 0.22 apart in summed RGB, so the nearer
    /// one is the colour the run was drawn in.
    private static func expectInkColor(_ actual: NSColor?, _ expected: NSColor, notLike other: NSColor, _ label: String) throws {
        guard let actual, let expected = expected.usingColorSpace(.deviceRGB), let other = other.usingColorSpace(.deviceRGB) else {
            throw TestFailure("\(label) should draw")
        }
        func distance(to color: NSColor) -> CGFloat {
            abs(actual.redComponent - color.redComponent) + abs(actual.greenComponent - color.greenComponent) + abs(actual.blueComponent - color.blueComponent)
        }
        try expect(distance(to: expected) < distance(to: other), "\(label) should be nearer \(expected) than \(other), got \(actual)")
    }

    /// Selected Filter Item.svg's chip: the label "Action:" in regular `textMetaHighlighted`, then the ticked names in bold
    /// `textBody`, and the chip grows with its text by exactly the characters it gains.
    private static func testWorkerLogChipNamesTheTicksInTheDesignsColoursAndGrowsWithThem() throws {
        func chip(_ summary: String) -> some View {
            WorkerLogChipRow(summary: summary, onClear: {}).fixedSize(horizontal: true, vertical: false)
        }
        let one = try fittingSize(of: chip("Status"))
        let several = try fittingSize(of: chip("Item, Message, Status, Summon"))
        let advance = ("A" as NSString).size(withAttributes: [.font: AppFonts.chipValue]).width
        let gained = CGFloat("Item, Message, Status, Summon".count - "Status".count) * advance
        try expect(abs(several.width - one.width - gained) <= 1, "the chip should grow by its extra characters (\(gained)), got \(several.width - one.width)")
        try expect(several.height == one.height, "and stay one line high")
        let manager = NSFontManager.shared
        try expect(manager.weight(of: AppFonts.chipValue) > manager.weight(of: AppFonts.questLogBody), "the value should be bolder than the label")

        let size = CGSize(width: 400, height: Space.row + ControlHeight.compact)
        let scale: CGFloat = 2
        let bitmap = try drawnBitmap(chip("Status"), size: size, scale: scale)
        // The chip's text starts past the row's inset, its border and `Space.item`.
        let labelStart = WorkerChatMetrics.inset + Token.Size.divider + Space.item
        let labelAdvance = ("A" as NSString).size(withAttributes: [.font: AppFonts.questLogBody]).width
        let valueStart = labelStart + 7 * labelAdvance + ClearableChipMetrics.labelGap
        try expectInkColor(brightestInk(bitmap, scale: scale, columns: labelStart..<(labelStart + 7 * labelAdvance)), AppPalette.metaHighlighted, notLike: AppPalette.textBody, "the label")
        try expectInkColor(brightestInk(bitmap, scale: scale, columns: valueStart..<(valueStart + 6 * advance)), AppPalette.textBody, notLike: AppPalette.metaHighlighted, "the value")
    }

    /// The filter chip's kind ("@type") is `textMetaHighlighted` and its title, after the kind's space, the body colour, both
    /// regular 12pt: the kind reads as a label, as the Worker Log's "Action:" does.
    private static func testFilterChipDrawsItsKindInMetaHighlightedAndItsTitleInBody() throws {
        let chip = FilterChip(token: ArtifactFilterToken(kind: .type, value: "bug", title: "Bug"), onRemove: {})
        let size = try fittingSize(of: chip)
        let scale: CGFloat = 2
        let bitmap = try drawnBitmap(chip, size: size, scale: scale)
        let advance = ("A" as NSString).size(withAttributes: [.font: AppFonts.questLogBody]).width
        // The text starts `Space.row` in; the kind is five characters, then the title's leading space.
        let kindStart = Space.row
        let titleStart = kindStart + 6 * advance
        try expectInkColor(brightestInk(bitmap, scale: scale, columns: kindStart..<(kindStart + 5 * advance)), AppPalette.metaHighlighted, notLike: AppPalette.textBody, "the kind")
        try expectInkColor(brightestInk(bitmap, scale: scale, columns: titleStart..<(titleStart + 3 * advance)), AppPalette.textBody, notLike: AppPalette.metaHighlighted, "the title")
    }

    /// The ticks outlive the attached master, but a log with nothing attached stays blank, chip and all.
    private static func testWorkerLogChipShowsOnlyWhileAMasterIsAttached() throws {
        let chat = WorkerChatStore()
        let sessions = [
            TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master"),
            TrackerSession(id: "w1", title: "Worker 1", repoName: "Repo", agent: "codex", role: "worker", parentID: "m"),
            TrackerSession(id: "sh", title: "Shell", repoName: "Repo", role: "shell"),
        ]
        _ = chat.sync(selectedSessionID: "m", sessions: sessions, isVisible: true)
        chat.toggleAction(at: 1)
        let size = CGSize(width: DockWidthPreference.panelWidth, height: 200)
        let hosting = NSHostingView(rootView: AnyView(WorkerChatDockView(store: chat, areaFocused: true).frame(maxWidth: .infinity, maxHeight: .infinity).background(AppPalette.panel.swiftUI)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size)
        window.contentView = hosting
        window.show()
        defer { window.close() }
        func ink() throws -> (top: CGFloat, bottom: CGFloat)? {
            try pumpOneMainRunLoopTurn()
            hosting.layoutSubtreeIfNeeded()
            return inkEdges(try snapshot(hosting, size: size, scale: 2), scale: 2, columns: 0..<Int(size.width), rows: 0..<Int(size.height), over: AppPalette.panel)
        }
        try expect(try ink() != nil, "the chip should show with a master attached")
        _ = chat.sync(selectedSessionID: "sh", sessions: sessions, isVisible: true)
        try expect(chat.filter.actions == [.item], "the ticks should survive the master going")
        try expect(try ink() == nil, "a log with nothing attached should be blank, without the chip")
        _ = chat.sync(selectedSessionID: "m", sessions: sessions, isVisible: true)
        try expect(try ink() != nil, "the chip should come back with the master")
    }

    /// The tab row alone at the panel's width, over the panel fill, selecting `selected`. Assign `rootView` to change it.
    private static func tabRowHost(workers: [WorkerLogWorker], selected: String?) throws -> (window: HeadlessWindow, hosting: NSHostingView<AnyView>, size: CGSize) {
        let size = CGSize(width: DockWidthPreference.panelWidth, height: TextTabMetrics.height)
        let hosting = NSHostingView(rootView: tabRow(workers: workers, selected: selected))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = HeadlessWindow(size: size)
        window.contentView = hosting
        window.show()
        try pumpOneMainRunLoopTurn()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting, size)
    }

    private static func tabRow(workers: [WorkerLogWorker], selected: String?) -> AnyView {
        AnyView(WorkerLogTabRow(workers: workers, selectedID: selected, areaFocused: true, onSelect: { _ in }).background(AppPalette.panel.swiftUI))
    }

    /// The tabs are set in the feed's 12pt chat font, the row holds a line of it, and a tab sits 5 from its diamond on each
    /// side. Solid blocks as the names fill their advance cell, so their ink ends where the text does.
    private static func testWorkerLogTabsUseTheChatFontAndFiveAroundEachDiamond() throws {
        try expect(AppFonts.workerTab.pointSize == 12 && AppFonts.workerTabSelected.pointSize == 12, "the tabs should be 12pt, got \(AppFonts.workerTab.pointSize)")
        let font = AppFonts.workerTab
        let line = (font.ascender - font.descender + font.leading).rounded(.up)
        try expect(TextTabMetrics.height >= line, "the row should hold a line of its text (\(line)), got \(TextTabMetrics.height) high")
        try expect(TextTabMetrics.labelBaseline - font.ascender >= 0 && TextTabMetrics.labelBaseline - font.descender <= TextTabMetrics.height, "and the baseline should keep the whole line inside it")
        try expect(TextTabMetrics.separatorGap == Space.row, "a tab should sit a `Space.row` from its diamond")

        // The ink measurements need the design font: a fallback's advance is fractional (the system monospaced face's is
        // 7.418), so the text's edges land between pixels and the ink gaps read up to a point short (CI has no JetBrains Mono).
        // Matched by prefix, since the same face patched is "JetBrainsMono Nerd Font".
        guard font.familyName?.hasPrefix("JetBrains") == true else {
            return
        }
        let blocks = String(repeating: "\u{2588}", count: 6)
        let workers = (1...2).map { WorkerLogWorker(id: "w\($0)", name: blocks) }
        let host = try tabRowHost(workers: workers, selected: nil)
        defer { host.window.close() }
        try pumpOneMainRunLoopTurn()
        let scale: CGFloat = 2
        let bitmap = try snapshot(host.hosting, size: host.size, scale: scale)
        guard let base = AppPalette.panel.usingColorSpace(.deviceRGB) else {
            throw TestFailure("the panel colour should convert")
        }
        // The row of pixels through the diamonds' centres: the blocks and the diamonds are the ink on it, and the text of All.
        let row = Int((TextTabMetrics.labelBaseline - TextTabMetrics.svgDiamondRaise) * scale)
        var runs: [(start: CGFloat, end: CGFloat)] = []
        var start: Int?
        for column in 0..<Int(host.size.width * scale) {
            let color = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB)
            let distance = color.map { abs($0.redComponent - base.redComponent) + abs($0.greenComponent - base.greenComponent) + abs($0.blueComponent - base.blueComponent) } ?? 0
            if distance > 0.1, start == nil {
                start = column
            } else if distance <= 0.1, let from = start {
                runs.append((CGFloat(from) / scale, CGFloat(column) / scale))
                start = nil
            }
        }
        try expect(runs.count >= 4, "the diamonds and blocks should draw four runs at the end of the row, got \(runs)")
        let (firstDiamond, firstBlock, secondDiamond, secondBlock) = (runs[runs.count - 4], runs[runs.count - 3], runs[runs.count - 2], runs[runs.count - 1])
        let gap = TextTabMetrics.separatorGap
        for (label, measured) in [("tab to its diamond", firstBlock.start - firstDiamond.end), ("first tab to the next diamond", secondDiamond.start - firstBlock.end), ("diamond to the next tab", secondBlock.start - secondDiamond.end)] {
            try expect(abs(measured - gap) <= 0.75, "\(label) should be \(gap) apart, got \(measured)")
        }
        let diamondWidth = secondDiamond.end - secondDiamond.start
        try expect(abs(diamondWidth - TextTabMetrics.svgDiamondDiagonal) <= 0.75, "the diamond should be \(TextTabMetrics.svgDiamondDiagonal) across, got \(diamondWidth)")
        let blockWidth = firstBlock.end - firstBlock.start
        let advance = ("\u{2588}" as NSString).size(withAttributes: [.font: font]).width
        try expect(abs(blockWidth - 6 * advance) <= 1.25, "six blocks should be six 12pt advances (\(6 * advance)) wide, got \(blockWidth)")
    }

    /// A row too wide for the panel scrolls sideways, and the selection comes to the middle when it changes: the first tab
    /// and the last stop at the row's ends, one between sits where the row can centre it.
    private static func testWorkerLogTabsScrollToTheSelection() throws {
        let names = ["Implement ABC-123", "Fix UI Bug", "Review API", "Add Tests", "Update Docs", "Audit Security", "Write Changelog", "Check Migrations", "Triage Reports"]
        let workers = names.enumerated().map { WorkerLogWorker(id: "w\($0.offset + 1)", name: $0.element) }
        let host = try tabRowHost(workers: workers, selected: nil)
        defer { host.window.close() }
        guard let scrollView = descendant(NSScrollView.self, in: host.hosting), let documentView = scrollView.documentView else {
            throw TestFailure("the tab row should scroll")
        }
        let clip = scrollView.contentView
        let farthest = documentView.bounds.width - clip.bounds.width
        try expect(farthest > 0, "nine tabs should be wider than the panel, got a document \(documentView.bounds.width) wide in \(clip.bounds.width)")
        try expect(clip.bounds.origin.x == 0, "the All tab starts at the row's left edge, got \(clip.bounds.origin.x)")

        host.hosting.rootView = tabRow(workers: workers, selected: "w9")
        try expect(waitUntil { clip.bounds.origin.x >= farthest - 1 }, "selecting the last tab should scroll it fully into view, got \(clip.bounds.origin.x) of \(farthest)")
        host.hosting.rootView = tabRow(workers: workers, selected: "w5")
        try expect(waitUntil { clip.bounds.origin.x > 1 && clip.bounds.origin.x < farthest - 1 }, "a tab in the middle should scroll to between the ends, got \(clip.bounds.origin.x) of \(farthest)")
        host.hosting.rootView = tabRow(workers: workers, selected: nil)
        try expect(waitUntil { clip.bounds.origin.x <= 1 }, "selecting All should scroll back to the start, got \(clip.bounds.origin.x)")

        let few = try tabRowHost(workers: Array(workers.prefix(3)), selected: "w3")
        defer { few.window.close() }
        guard let fewScroll = descendant(NSScrollView.self, in: few.hosting), let fewDocument = fewScroll.documentView else {
            throw TestFailure("a short tab row should still be a scroll view")
        }
        try expect(fewDocument.bounds.width <= fewScroll.contentView.bounds.width + 0.5 && fewScroll.contentView.bounds.origin.x == 0, "tabs that fit the panel should not scroll")
    }

    /// A side with tabs hidden past it fades out over the feed's top-fade width, from nothing at the edge. Solid blocks as
    /// the names make each column's ink the mask's alpha; two tabs a panel's width each leave ink under both edges.
    private static func testWorkerLogTabsFadeOnlyTheSidesWithHiddenTabs() throws {
        let blocks = String(repeating: "\u{2588}", count: 80)
        let workers = (1...2).map { WorkerLogWorker(id: "w\($0)", name: blocks) }
        let host = try tabRowHost(workers: workers, selected: nil)
        defer { host.window.close() }
        guard let scrollView = descendant(NSScrollView.self, in: host.hosting) else {
            throw TestFailure("the tab row should scroll")
        }
        guard let base = AppPalette.panel.usingColorSpace(.deviceRGB) else {
            throw TestFailure("the panel colour should convert")
        }
        let scale: CGFloat = 2
        let width = host.size.width
        let fade = TextTabMetrics.fadeWidth
        /// The block's coverage in the column at `x` points: its distance from the panel fill, as a share of `full`.
        func coverage(_ bitmap: NSBitmapImageRep, atX x: CGFloat, full: CGFloat) -> CGFloat {
            let column = Int(x * scale)
            let distance = (Int(11 * scale)..<Int(15 * scale)).map { row -> CGFloat in
                guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else {
                    return 0
                }
                return abs(pixel.redComponent - base.redComponent) + abs(pixel.greenComponent - base.greenComponent)
                    + abs(pixel.blueComponent - base.blueComponent)
            }.max() ?? 0
            return distance / full
        }
        /// Fully inked in the middle, near nothing at the edge, and rising across the fade.
        func expectFade(_ bitmap: NSBitmapImageRep, edge: (CGFloat) -> CGFloat, _ side: String) throws {
            let full = coverage(bitmap, atX: edge(fade + 20), full: 1)
            try expect(full > 0.3, "a tab should show in full inside the \(side) fade's reach, got \(full)")
            for distance in stride(from: CGFloat(0.5), to: fade, by: 1.5) {
                let value = coverage(bitmap, atX: edge(distance), full: full)
                let allowed = distance / fade + 0.12
                try expect(value <= allowed, "ink \(distance)pt from the \(side) edge should be at most \(allowed) of full, got \(value)")
            }
            let inner = coverage(bitmap, atX: edge(fade - 1), full: full)
            try expect(inner > 0.6, "the \(side) fade should reach full strength by its inner end, got \(inner)")
        }

        try pumpOneMainRunLoopTurn()
        try expectFade(try snapshot(host.hosting, size: host.size, scale: scale), edge: { width - $0 }, "trailing")

        // Scrolled into the middle of the first tab, tabs hang past both edges.
        scrollView.contentView.scroll(to: NSPoint(x: 200, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try pumpOneMainRunLoopTurn()
        let middle = try snapshot(host.hosting, size: host.size, scale: scale)
        try expectFade(middle, edge: { width - $0 }, "trailing")
        try expectFade(middle, edge: { $0 }, "leading")
    }

    /// The feed ends where the row begins, and the row ends `bottomInset` above the panel's edge. The row
    /// shows from two workers on: a master with none or one has no row at all, and the feed fills the panel.
    /// The Quest Log's project tabs sit centred in their column while they fit, as the Worker Log's do. Wider than the column
    /// they start at the leading edge and scroll sideways.
    private static func testQuestLogTabsCentreWhenTheyFit() throws {
        let fitting = try questLogTabInk(projectNames: ["dotfiles", "questmaster", "scry"])
        try expect(!fitting.scrolls, "three short projects should fit the Quest Log's column")
        try expect(fitting.left > 20, "the Quest Log's tabs should sit in from the leading edge, got \(fitting.left) on the left")
        try expect(abs(fitting.left - fitting.right) <= 1, "the Quest Log's tabs should be centred: \(fitting.left) on the left, \(fitting.right) on the right")

        let overflowing = try questLogTabInk(projectNames: (1...8).map { "a-long-project-name-\($0)" })
        try expect(overflowing.scrolls, "eight long projects should overflow the column and scroll")
        try expect(overflowing.left < 1, "overflowing tabs should start at the leading edge, got \(overflowing.left) on the left")

        // The Worker Log's row was always centred; the Quest Log's change must not move it.
        let worker = try tabRowHost(workers: (1...2).map { WorkerLogWorker(id: "w\($0)", name: "Worker \($0)") }, selected: nil)
        defer { worker.window.close() }
        guard let workerTabs = descendant(NSScrollView.self, in: worker.hosting) else {
            throw TestFailure("the Worker Log's tab row should scroll")
        }
        let workerInk = try tabInkGaps(in: worker.hosting, size: worker.size, tabs: workerTabs)
        try expect(abs(workerInk.left - workerInk.right) <= 1 && workerInk.left > 20, "the Worker Log's tabs should stay centred, got \(workerInk.left) and \(workerInk.right)")
    }

    /// The Quest Log hosted at its sheet size, with one project tab per name, and the ink gaps of its tab row.
    private static func questLogTabInk(projectNames: [String]) throws -> (left: CGFloat, right: CGFloat, scrolls: Bool) {
        let store = QuestLogStore()
        store.sync(
            quests: projectNames.enumerated().map { index, name in QuestItem(id: "q\(index)", content: "Quest \(index)", projectID: "p\(index)", projectName: name) },
            repos: []
        )
        let layout = QuestLogLayout(sheetSize: QuestLogMetrics.sheetSize)
        let hosting = NSHostingView(rootView: QuestLogView(store: store, filter: QuestLogFilter(), layout: layout, onCommand: { _ in }))
        hosting.frame = NSRect(origin: .zero, size: layout.sheetSize)
        let window = HeadlessWindow(size: layout.sheetSize)
        window.contentView = hosting
        window.show()
        defer { window.close() }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { ((($0 as? NSScrollView).map { [$0] }) ?? []) + scrollViews(in: $0) }
        }
        var tabRow: NSScrollView?
        guard waitUntil({
            tabRow = scrollViews(in: hosting).first(where: { $0.frame.height == TextTabMetrics.height })
            return tabRow != nil
        }), let tabs = tabRow else {
            throw TestFailure("the Quest Log should have a tab row \(TextTabMetrics.height) high")
        }
        hosting.layoutSubtreeIfNeeded()
        return try tabInkGaps(in: hosting, size: layout.sheetSize, tabs: tabs)
    }

    /// Where a tab row's ink starts and ends, as gaps to its two edges in points, read from a snapshot of `hosting`. A
    /// row that scrolls reports `scrolls` and no centring is measured for it.
    private static func tabInkGaps(in hosting: NSView, size: CGSize, tabs: NSScrollView) throws -> (left: CGFloat, right: CGFloat, scrolls: Bool) {
        let scale: CGFloat = 2
        guard waitUntil({ (tabs.documentView?.frame.width ?? 0) > 0 }) else {
            throw TestFailure("the tab row should lay out before it is read")
        }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try snapshot(hosting, size: size, scale: scale)
        let band = tabs.convert(tabs.bounds, to: hosting)
        let rows = Int(band.minY * scale)..<Int(band.maxY * scale)
        let firstColumn = Int(band.minX * scale)
        guard let background = bitmap.colorAt(x: firstColumn, y: rows.lowerBound)?.usingColorSpace(.deviceRGB) else {
            throw TestFailure("the tab row's background should read")
        }
        func inked(_ column: Int) -> Bool {
            rows.contains { row in
                guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB) else {
                    return false
                }
                return abs(pixel.redComponent - background.redComponent) + abs(pixel.greenComponent - background.greenComponent)
                    + abs(pixel.blueComponent - background.blueComponent) > 0.12
            }
        }
        let columns = firstColumn..<min(Int(band.maxX * scale), bitmap.pixelsWide)
        guard let first = columns.first(where: inked), let last = columns.last(where: inked) else {
            throw TestFailure("the tab row should show some ink")
        }
        let scrolls = (tabs.documentView?.frame.width ?? 0) > tabs.contentView.bounds.width + 0.5
        return (
            left: CGFloat(first - firstColumn) / scale,
            right: band.maxX - CGFloat(last + 1) / scale,
            scrolls: scrolls
        )
    }

    private static func testWorkerLogTabsSitUnderTheFeedAndNeedTwoWorkers() throws {
        func host(workers: Int) throws -> (window: HeadlessWindow, hosting: NSHostingView<AnyView>) {
            let chat = WorkerChatStore()
            let sessions = [TrackerSession(id: "m", title: "Master", repoName: "Repo", role: "master")]
                + (0..<workers).map { TrackerSession(id: "w\($0 + 1)", title: "Worker \($0 + 1)", repoName: "Repo", agent: "codex", role: "worker", parentID: "m") }
            let request = chat.sync(selectedSessionID: "m", sessions: sessions, isVisible: true)
            let entries = (0..<30).map { WorkerFeedEntry(timestamp: String(format: "2026-10-07T08:%02d:00.000Z", $0), workerID: "w1", workerTitle: "Worker 1", kind: "say", text: "line \($0)") }
            if let request {
                _ = chat.receive(WorkerFeedPayload(entries: workers > 0 ? entries : []), for: request)
            }
            let size = CGSize(width: DockWidthPreference.panelWidth, height: 400)
            let hosting = NSHostingView(rootView: AnyView(WorkerChatDockView(store: chat, areaFocused: true).background(AppPalette.panel.swiftUI)))
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = HeadlessWindow(size: size)
            window.contentView = hosting
            window.show()
            try pumpOneMainRunLoopTurn()
            hosting.layoutSubtreeIfNeeded()
            return (window, hosting)
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }

        let alone = try host(workers: 0)
        defer { alone.window.close() }
        try expect(scrollViews(in: alone.hosting).isEmpty, "a master with no workers should have no tab row")

        let single = try host(workers: 1)
        defer { single.window.close() }
        let singleScrolls = scrollViews(in: single.hosting)
        try expect(singleScrolls.count == 1, "a master with one worker should have only the feed's scroll view, got \(singleScrolls.count)")
        if let feed = singleScrolls.first {
            let rect = feed.convert(feed.bounds, to: single.hosting)
            let fromBottom = single.hosting.isFlipped ? single.hosting.bounds.height - rect.maxY : rect.minY
            try expect(abs(fromBottom) < 0.5, "and the feed should fill the panel to its bottom edge, got \(fromBottom) above it")
        }

        let tabs = try host(workers: 2)
        defer { tabs.window.close() }
        let all = scrollViews(in: tabs.hosting)
        try expect(all.count == 2, "the feed and the tab row should both scroll, got \(all.count) scroll views")
        func frame(_ scrollView: NSScrollView) -> CGRect {
            let rect = scrollView.convert(scrollView.bounds, to: tabs.hosting)
            // Measured from the panel's bottom, whichever way the hosting view's y runs.
            return tabs.hosting.isFlipped ? CGRect(x: rect.minX, y: tabs.hosting.bounds.height - rect.maxY, width: rect.width, height: rect.height) : rect
        }
        let frames = all.map(frame).sorted { $0.minY < $1.minY }
        let (row, feed) = (frames[0], frames[1])
        try expect(row.height == TextTabMetrics.height, "the tab row should be \(TextTabMetrics.height) high, got \(row.height)")
        try expect(abs(row.minY - WorkerLogTabMetrics.bottomInset) < 0.5, "the row should end \(WorkerLogTabMetrics.bottomInset) above the panel's bottom, got \(row.minY)")
        try expect(abs(feed.minY - row.maxY) < 0.5, "the feed should end where the row begins, got its bottom at \(feed.minY) over the row's top at \(row.maxY)")
        try expect(feed.width == DockWidthPreference.panelWidth, "the feed should span the panel, got \(feed.width)")
        let side = WorkerLogTabMetrics.sideInset
        try expect(row.minX == side && row.width == DockWidthPreference.panelWidth - 2 * side,
                   "the tab row should sit \(side) in from both panel edges, got x \(row.minX) width \(row.width)")
    }

    private static func fittingSize<V: View>(of view: V) throws -> CGSize {
        let hosting = NSHostingView(rootView: view)
        let window = HeadlessWindow(size: CGSize(width: 600, height: 600))
        window.contentView = hosting
        window.show()
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize
    }

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

    /// A list row asks for its logo on every redraw, so the same agent, side and tint must come back as the same image,
    /// read and parsed once. A different side or tint is a different image: a cache that ignored either would draw a
    /// plate's logo at the tab's size, or in the wrong colour.
    private static func testAgentLogosAreLoadedOncePerSideAndTint() throws {
        func logo(_ agent: String, _ side: CGFloat, _ tint: NSColor) throws -> NSImage {
            guard let image = TrackerAgentMark.image(for: agent, side: side, tint: tint) else {
                throw TestFailure("\(agent) should have a logo")
            }
            return image
        }
        let side = PullRequestIcon.side
        let tint = AppPalette.agentMarkTint
        for agent in ["claude", "codex", "opencode", "pi"] {
            let first = try logo(agent, side, tint)
            try expect(first === (try logo(agent, side, tint)), "\(agent): the same side and tint should return the cached image")

            let larger = try logo(agent, side + 5, tint)
            try expect(larger !== first, "\(agent): another side should be another image")
            try expect(larger.size == NSSize(width: side + 5, height: side + 5), "\(agent): the larger logo should keep its own canvas")
            try expect(first.size == NSSize(width: side, height: side), "\(agent): the first logo should keep its canvas")
        }

        // Codex and OpenCode are tinted files, so their colour is part of the key. Claude and Pi draw in their own colours.
        let grey = try logo("codex", side, AppPalette.agentMarkTint)
        let muted = try logo("codex", side, AppPalette.muted)
        try expect(grey !== muted, "codex: another tint should be another image")
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

    /// Runs main-run-loop events until `condition` holds or the named self-test wait timeout expires.
    private static func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(selfTestWaitTimeout)
        while !condition() {
            guard Date() < deadline else {
                return false
            }
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
        return true
    }

    private static func hasAnimations(in layer: CALayer?) -> Bool {
        guard let layer else {
            return false
        }
        return !(layer.animationKeys() ?? []).isEmpty || (layer.sublayers ?? []).contains { hasAnimations(in: $0) }
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
        try expect(glide.duration == MotionStep.standard.seconds, "the glide should last the standard step, \(MotionStep.standard.seconds)s, got \(glide.duration)")
        try expect(glide.timingFunction == Motion.timingFunction, "the glide should take the shared easing")
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

    /// Checks a fade: opacity from transparent to opaque over the standard step. The model stays opaque, so
    /// the rows are fully visible once the fade is gone.
    private static func expectFade(_ fade: CABasicAnimation, on band: CALayer) throws {
        try expect(fade.keyPath == "opacity", "the fade should animate opacity, got \(String(describing: fade.keyPath))")
        try expect((fade.fromValue as? NSNumber)?.doubleValue == 0, "the fade should start transparent, got \(String(describing: fade.fromValue))")
        try expect((fade.toValue as? NSNumber)?.doubleValue == 1, "the fade should end opaque, got \(String(describing: fade.toValue))")
        try expect(fade.duration == MotionStep.standard.seconds, "the fade should last the standard step, \(MotionStep.standard.seconds)s, got \(fade.duration)")
        try expect(fade.timingFunction == Motion.timingFunction, "the fade should take the shared easing")
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
        try pumpOneMainRunLoopTurn()
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
        try pumpOneMainRunLoopTurn()
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
        try pumpOneMainRunLoopTurn()
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
                effortClient: effortClient,
                runtime: RuntimeStore(sourceLabel: "test")
            ),
            dismiss: dismiss
        )
    }

    private static func sessionCoordinator(
        client: ServeMutationSending,
        failures: Counter,
        switches: Counter? = nil,
        ended: Counter? = nil
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
                clearTerminalEnded: {},
                showTerminalEnded: { ended?.value += 1 },
                render: {}
            )
        )
    }

    private static func waitForMainQueue(
        _ description: String,
        until condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(selfTestWaitTimeout)
        while !condition() {
            guard Date() < deadline else {
                throw TestFailure("timed out after \(selfTestWaitTimeout)s waiting for \(description)")
            }
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
    }

    private static func waitForMainQueueTurn() throws {
        var didRun = false
        DispatchQueue.main.async {
            didRun = true
        }
        try waitForMainQueue("queued main-thread work", until: { didRun })
    }

    /// A press at the dock's model, resolved as `SwiftUIDockPane` resolves it for the content shown (`in:`, the artifact
    /// list's by default, none in the viewer). `keys` is the dock's resolver, kept across presses so a `gg` carries over.
    private static func dockKey(
        _ event: NSEvent,
        _ keys: inout ListKeyResolver,
        _ model: DockPaneModel,
        _ snapshot: RuntimeSnapshot,
        in capabilities: ListCapabilities = .artifacts
    ) -> Bool {
        model.handleKeyDown(event, command: keys.command(for: event.keymapPress, in: capabilities), snapshot: snapshot)
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

    private final class StubDirectoryClient: ServeDirectorySuggesting {
        private let suggestions: [String]
        private(set) var queries: [String] = []

        init(suggestions: [String]) {
            self.suggestions = suggestions
        }

        func suggestDirectories(query: String, completion: @escaping (Result<DirectorySuggestionResponse, Error>) -> Void) {
            queries.append(query)
            completion(.success(DirectorySuggestionResponse(suggestions: suggestions, recents: [])))
        }
    }

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

    private static func testBoundedProcessDrainsBothPipesPastCapacity() throws {
        let result = try BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 1200000 /dev/zero; head -c 1200000 /dev/zero >&2"],
            environment: [:]
        )
        try expect(result.outcome == .capped, "both streams must drain past the cap without deadlocking")
        try expect(result.stdout.count == BoundedProcess.streamLimit && result.stderr.count == BoundedProcess.streamLimit,
                   "each stream must keep at most its own cap")
    }

    private static func testBoundedProcessCapsOutput() throws {
        let result = try BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 1200000 /dev/zero"],
            environment: [:]
        )
        try expect(result.outcome == .capped && result.stdout.count == BoundedProcess.streamLimit,
                   "an overlong stdout must have a typed capped result")
    }

    private static func testBoundedProcessTimesOutAChildIgnoringTerm() throws {
        let started = ProcessInfo.processInfo.systemUptime
        let result = try BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            environment: [:], deadline: 0.15
        )
        try expect(result.outcome == .timeout, "the child must time out after TERM and KILL")
        try expect(ProcessInfo.processInfo.systemUptime - started < boundedProcessTimeoutWatchdog, "the timed out child must be reaped promptly")
    }

    private static func testBoundedProcessReapsWithHeldOpenPipe() throws {
        let pidURL = FileManager.default.temporaryDirectory.appendingPathComponent("qm-held-pipe-\(UUID().uuidString).pid")
        defer {
            if let rawPID = try? String(contentsOf: pidURL, encoding: .utf8), let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                _ = Darwin.kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: pidURL)
        }
        let result = try BoundedProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", "/bin/sleep \(Int(heldPipeGrandchildLifetime)) & echo $! > \"$QM_TEST_CHILD_PID_FILE\"; exit 0"],
            environment: ["QM_TEST_CHILD_PID_FILE": pidURL.path]
        )
        try expect(result.outcome == .exit(0), "the direct child must exit successfully")
        guard let rawPID = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TestFailure("the grandchild should record its PID")
        }
        try expect(Darwin.kill(pid, 0) == 0, "a live grandchild should still hold the pipe when the direct child is reaped")
    }

    private static func testConnectReturnsToMainPromptlyWithBlockedRunner() throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let entered = DispatchSemaphore(value: 0)
        let attach = AsyncTerminalAttach<String>()
        attach.request(work: { entered.signal(); release.wait(); return .success("ready") }, completion: { _ in })
        try waitForSemaphore(entered, description: "the attach runner to enter its blocked work")
        release.signal()
    }

    private static func testOutOfOrderConnectsOnlyNewestMutates() throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let entered = DispatchSemaphore(value: 0)
        var calls = 0
        var applied: [String] = []
        let attach = AsyncTerminalAttach<String>()
        let work: () -> Result<String, Error> = {
            calls += 1
            if calls == 1 { entered.signal(); release.wait() }
            return .success("result-\(calls)")
        }
        attach.request(work: work) { result in if case .success(let value) = result { applied.append(value) } }
        try waitForSemaphore(entered, description: "the first attach runner to enter its blocked work")
        attach.request(work: work) { result in if case .success(let value) = result { applied.append(value) } }
        release.signal()
        try expect(waitUntil { applied.count == 1 }, "the newest completion must arrive")
        try expect(applied == ["result-2"], "only the newest result may mutate visible state")

        final class FakeHost: TerminalPaneHosting {
            let view = NSView()
            var tmuxSessionID: String? { nil }
            var onFocusRequested: (() -> Void)?
            var onDetach: (() -> Void)?
            var cellMetrics: TerminalCellMetrics { .unavailable }
            var onCellMetricsChanged: (() -> Void)?
            var pending: [(Result<String?, Error>) -> Void] = []
            var starts = 0
            func start() { starts += 1 }
            func stop() {}
            func focus(in window: NSWindow?) {}
            func connect(to config: TerminalLaunchConfig, completion: @escaping (Result<String?, Error>) -> Void) {
                pending.append(completion)
            }
        }
        final class FakeRoutes: ServeTmuxRouting {
            var pending: [(Result<[TmuxRoute], Error>) -> Void] = []
            func fetchTmuxRoutes(sessionIDs: [String], live: Bool, completion: @escaping (Result<[TmuxRoute], Error>) -> Void) {
                pending.append(completion)
            }
        }
        let config = LaunchConfiguration(
            daemonSocketOverride: nil, startDaemon: false, tmuxSession: nil,
            disableTmux: false,
            workingDirectory: "/tmp", backend: AppBackend(
                stateRoot: "/tmp/example-state", executablePath: "", source: .unresolved,
                workingDirectory: "/tmp", devWorktree: nil
            )
        )
        let runtime = RuntimeStore(sourceLabel: "test")
        let fake = FakeHost()
        let routes = FakeRoutes()
        let controller = TerminalSessionController(
            config: config, runtimeStore: runtime, routeClient: routes, terminalShell: { nil },
            updateWindowTitle: { _ in }, focusTerminal: {}, render: {},
            showMutationFailure: { _, _ in }, showMutationError: { _, _ in },
            showTerminalEngineFailure: { _ in }, onFocusRequested: {}
        )
        controller.installPlaceholder(fake)
        var completions: [Bool] = []
        controller.switchTerminal(to: "qm-old") { completions.append($0) }
        controller.switchTerminal(to: "qm-new") { completions.append($0) }
        try expect(routes.pending.count == 2, "the route client must hold both lookups")
        routes.pending[1](.success([try TmuxRoute(sessionID: "qm-new", label: "default", configFiles: [], live: true, createdUnix: 1)]))
        try expect(waitUntil { fake.pending.count == 1 }, "newest route should reach host")
        routes.pending[0](.success([try TmuxRoute(sessionID: "qm-old", label: "default", configFiles: [], live: true, createdUnix: 1)]))
        fake.pending[0](.success("qm-new"))
        try expect(runtime.currentTerminalSessionID == "qm-new" && fake.starts == 1,
                   "the controller must apply only the newest attach result")
        try expect(completions == [false, true], "a superseded activation must finish false and the newest true")

        controller.switchTerminal(to: "qm-detach") { completions.append($0) }
        routes.pending[2](.success([try TmuxRoute(sessionID: "qm-detach", label: "default", configFiles: [], live: true, createdUnix: 1)]))
        try expect(waitUntil { fake.pending.count == 2 }, "detach target should reach host")
        fake.onDetach?()
        fake.pending[1](.success("qm-detach"))
        try expect(runtime.currentTerminalSessionID == nil && completions.last == false,
                   "detach must discard a pending attach")

        controller.switchTerminal(to: "qm-stop") { completions.append($0) }
        routes.pending[3](.success([try TmuxRoute(sessionID: "qm-stop", label: "default", configFiles: [], live: true, createdUnix: 1)]))
        try expect(waitUntil { fake.pending.count == 3 }, "stop target should reach host")
        controller.stop()
        fake.pending[2](.success("qm-stop"))
        try expect(runtime.currentTerminalSessionID == nil && fake.starts == 1 && completions.last == false,
                   "stop must discard a pending attach")
    }

    private static func testEditorWindowOpensOffMain() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let done = DispatchSemaphore(value: 0)
        var ranOnMain = true
        ArtifactExternalOpener.dispatchEditorWindow(run: {
            ranOnMain = Thread.isMainThread
            entered.signal()
            release.wait()
            done.signal()
        })
        try waitForSemaphore(entered, description: "editor work to start off the main thread")
        release.signal()
        try waitForSemaphore(done, description: "editor work to finish")
        try expect(!ranOnMain, "editor tmux work must run off main")
    }

    private static func testLoginEnvironmentNeverBlocksUI() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let cache = LoginShellEnvironmentCache(load: { entered.signal(); release.wait(); return ["PATH": "/test"] })
        cache.preload()
        try waitForSemaphore(entered, description: "the login environment probe to start")
        let pending = cache.environment()
        try expect(pending.isEmpty, "a UI caller must use the current environment while the login probe loads")
        release.signal()
        try expect(waitUntil { cache.environment()["PATH"] == "/test" }, "the loaded login environment must become available")
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    var description: String

    init(_ description: String) {
        self.description = description
    }
}

/// A blocker whose compile waits until the test fails it, as WebKit rejects a rule list. Holding the completion keeps
/// the page view in the tree long enough for the test to capture it; a compile that failed at once would be gone first.
private final class DeferredRuleListCompiler: ArtifactRuleListCompiling {
    private(set) var attempts = 0
    private var pendingCompletion: ((WKContentRuleList?, Error?) -> Void)?

    func compileRuleList(
        identifier: String,
        encodedRules: String,
        completion: @escaping (WKContentRuleList?, Error?) -> Void
    ) {
        attempts += 1
        pendingCompletion = completion
    }

    func failCompile() {
        pendingCompletion?(nil, TestFailure("injected rule list failure"))
        pendingCompletion = nil
    }
}
#endif
