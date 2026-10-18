import Foundation
import XCTest
@testable import Shirayuki

final class CommentPageSwipeTests: XCTestCase {
    func testShortPageThresholdBoundsAndSingleRelease() {
        var swipe = CommentPageSwipe()
        swipe.update(translation: .zero, atTop: true, atBottom: true, page: 2, pages: 3, enabled: true)
        swipe.update(translation: CGSize(width: 0, height: -71), atTop: true, atBottom: true, page: 2, pages: 3, enabled: true)
        XCTAssertNil(swipe.destination)
        swipe.update(translation: CGSize(width: 0, height: -72), atTop: true, atBottom: true, page: 2, pages: 3, enabled: true)
        XCTAssertEqual(swipe.destination, 3)
        XCTAssertEqual(swipe.finish(translation: CGSize(width: 0, height: -72), atTop: true, atBottom: true, page: 2, pages: 3, enabled: true), 3)
        XCTAssertNil(swipe.finish(translation: CGSize(width: 0, height: -72), atTop: true, atBottom: true, page: 2, pages: 3, enabled: true))

        swipe.update(translation: CGSize(width: 0, height: 80), atTop: true, atBottom: true, page: 2, pages: 3, enabled: true)
        XCTAssertEqual(swipe.destination, 1)
        swipe.reset()
        swipe.update(translation: CGSize(width: 0, height: 100), atTop: true, atBottom: true, page: 1, pages: 3, enabled: true)
        XCTAssertNil(swipe.destination)
        swipe.reset()
        swipe.update(translation: CGSize(width: 0, height: -100), atTop: true, atBottom: true, page: 3, pages: 3, enabled: true)
        XCTAssertNil(swipe.destination)
    }

    func testOrdinaryScrollingDoesNotCountTowardEdgeThresholdAndDraggingBackCancels() {
        var swipe = CommentPageSwipe()
        swipe.update(translation: CGSize(width: 0, height: -500), atTop: false, atBottom: false, page: 2, pages: 3, enabled: true)
        swipe.update(translation: CGSize(width: 0, height: -600), atTop: false, atBottom: true, page: 2, pages: 3, enabled: true)
        XCTAssertNil(swipe.destination)
        swipe.update(translation: CGSize(width: 0, height: -671), atTop: false, atBottom: true, page: 2, pages: 3, enabled: true)
        XCTAssertNil(swipe.destination)
        swipe.update(translation: CGSize(width: 0, height: -672), atTop: false, atBottom: true, page: 2, pages: 3, enabled: true)
        XCTAssertEqual(swipe.destination, 3)
        XCTAssertNil(swipe.finish(translation: CGSize(width: 0, height: -640), atTop: false, atBottom: true, page: 2, pages: 3, enabled: true))
    }

    func testLongDragCanReachOppositeEdgeButDisabledOrHorizontalDragCannotTurnPage() {
        var swipe = CommentPageSwipe()
        swipe.update(translation: CGSize(width: 0, height: -20), atTop: true, atBottom: false, page: 1, pages: 3, enabled: true)
        swipe.update(translation: CGSize(width: 0, height: -200), atTop: false, atBottom: false, page: 1, pages: 3, enabled: true)
        swipe.update(translation: CGSize(width: 0, height: -500), atTop: false, atBottom: true, page: 1, pages: 3, enabled: true)
        XCTAssertEqual(swipe.finish(translation: CGSize(width: 0, height: -572), atTop: false, atBottom: true, page: 1, pages: 3, enabled: true), 2)
        swipe.update(translation: CGSize(width: 200, height: -80), atTop: true, atBottom: true, page: 1, pages: 3, enabled: true)
        XCTAssertNil(swipe.destination)
        swipe.update(translation: CGSize(width: 0, height: -100), atTop: true, atBottom: true, page: 1, pages: 3, enabled: false)
        XCTAssertNil(swipe.finish(translation: CGSize(width: 0, height: -100), atTop: true, atBottom: true, page: 1, pages: 3, enabled: false))
    }
}
