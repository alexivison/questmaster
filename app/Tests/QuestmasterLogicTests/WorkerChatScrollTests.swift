import CoreGraphics
import Foundation
import QuestmasterCore

struct WorkerChatScrollTests {
    static func run() {
        bottomEdgeInViewFollows()
        scrollingAboveTheBottomStopsFollowing()
        shortContentIsAlwaysAtTheBottomAndNeedsNoScroll()
        bottomOffsetShowsTheLastPoint()
        print("WorkerChatScrollTests: all tests passed")
    }

    private static func bottomEdgeInViewFollows() {
        expect(WorkerChatScroll.isAtBottom(offset: 600, viewportHeight: 400, contentHeight: 1000), "exact bottom should follow")
        expect(WorkerChatScroll.isAtBottom(offset: 598.5, viewportHeight: 400, contentHeight: 1000), "within tolerance should follow")
        expect(WorkerChatScroll.isAtBottom(offset: 640, viewportHeight: 400, contentHeight: 1000), "rubber-banding past the bottom should follow")
    }

    private static func scrollingAboveTheBottomStopsFollowing() {
        expect(!WorkerChatScroll.isAtBottom(offset: 552, viewportHeight: 400, contentHeight: 1000), "one k (48pt) up should stop following")
        expect(!WorkerChatScroll.isAtBottom(offset: 0, viewportHeight: 400, contentHeight: 1000), "the top should not follow")
    }

    private static func shortContentIsAlwaysAtTheBottomAndNeedsNoScroll() {
        expect(WorkerChatScroll.isAtBottom(offset: -252, viewportHeight: 400, contentHeight: 148), "short content hugs the bottom")
        expect(WorkerChatScroll.bottomOffset(viewportHeight: 400, contentHeight: 148) == nil, "short content has no bottom offset")
    }

    private static func bottomOffsetShowsTheLastPoint() {
        expect(WorkerChatScroll.bottomOffset(viewportHeight: 400, contentHeight: 1000) == 600, "bottom offset should be content minus viewport")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("WorkerChatScrollTests failed: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }
}
