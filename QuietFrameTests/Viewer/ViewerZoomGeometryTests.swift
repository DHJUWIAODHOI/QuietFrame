import CoreGraphics
import XCTest
@testable import QuietFrame

@MainActor
final class ViewerZoomGeometryTests: XCTestCase {
    func testAspectFitRectCentersWideImageInTallBounds() {
        let rect = aspectFitRect(imageSize: CGSize(width: 4_000, height: 3_000), in: CGRect(x: 0, y: 0, width: 400, height: 800))

        XCTAssertEqual(rect.width, 400, accuracy: 0.001)
        XCTAssertEqual(rect.height, 300, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 250, accuracy: 0.001)
    }

    func testAspectFitRectCentersTallImageInWideBoundsWithOffsetOrigin() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 400)
        let rect = aspectFitRect(imageSize: CGSize(width: 300, height: 600), in: bounds)

        XCTAssertEqual(rect.width, 200, accuracy: 0.001)
        XCTAssertEqual(rect.height, 400, accuracy: 0.001)
        XCTAssertEqual(rect.midX, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 20, accuracy: 0.001)
    }

    func testAspectFitRectFillsBoundsWithMatchingAspectRatio() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)

        XCTAssertEqual(aspectFitRect(imageSize: CGSize(width: 30, height: 20), in: bounds), bounds)
    }

    func testAspectFitRectFallsBackToBoundsForZeroSizes() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)

        XCTAssertEqual(aspectFitRect(imageSize: .zero, in: bounds), bounds)
        XCTAssertEqual(aspectFitRect(imageSize: CGSize(width: 100, height: 0), in: bounds), bounds)
        XCTAssertEqual(aspectFitRect(imageSize: CGSize(width: 100, height: 100), in: .zero), .zero)
    }

    func testDismissProgressClampsBetweenRestAndFullHeight() {
        XCTAssertEqual(dismissProgress(translation: 0, height: 800), 0, accuracy: 0.001)
        XCTAssertEqual(dismissProgress(translation: 200, height: 800), 0.25, accuracy: 0.001)
        XCTAssertEqual(dismissProgress(translation: 1_600, height: 800), 1, accuracy: 0.001)
        XCTAssertEqual(dismissProgress(translation: -120, height: 800), 0, accuracy: 0.001)
        XCTAssertEqual(dismissProgress(translation: 120, height: 0), 0, accuracy: 0.001)
    }

    func testDragScaleShrinksTowardsSixtyFivePercent() {
        XCTAssertEqual(dragScale(progress: 0, reduceMotion: false), 1, accuracy: 0.001)
        XCTAssertEqual(dragScale(progress: 0.5, reduceMotion: false), 0.825, accuracy: 0.001)
        XCTAssertEqual(dragScale(progress: 1, reduceMotion: false), 0.65, accuracy: 0.001)
        XCTAssertEqual(dragScale(progress: 3, reduceMotion: false), 0.65, accuracy: 0.001)
        XCTAssertEqual(dragScale(progress: -1, reduceMotion: false), 1, accuracy: 0.001)
    }

    func testDragScaleStaysFullSizeWithReduceMotion() {
        XCTAssertEqual(dragScale(progress: 0.5, reduceMotion: true), 1, accuracy: 0.001)
        XCTAssertEqual(dragScale(progress: 1, reduceMotion: true), 1, accuracy: 0.001)
    }

    func testShouldDismissPastDistanceThreshold() {
        XCTAssertTrue(shouldDismiss(translation: 121, velocity: 0))
        XCTAssertFalse(shouldDismiss(translation: 120, velocity: 0))
        XCTAssertFalse(shouldDismiss(translation: 60, velocity: 0))
    }

    func testShouldDismissOnShortFastFlick() {
        XCTAssertTrue(shouldDismiss(translation: 13, velocity: 401))
        XCTAssertFalse(shouldDismiss(translation: 12, velocity: 2_000))
        XCTAssertFalse(shouldDismiss(translation: 60, velocity: 400))
    }

    func testShouldNotDismissUpwardDrags() {
        XCTAssertFalse(shouldDismiss(translation: -200, velocity: 2_000))
        XCTAssertFalse(shouldDismiss(translation: -200, velocity: -2_000))
        XCTAssertFalse(shouldDismiss(translation: 60, velocity: -2_000))
    }

    func testBackdropThinsOutWithTranslationAndKeepsAFloor() {
        XCTAssertEqual(backdropOpacity(translation: 0, height: 1_000), 1, accuracy: 0.001)
        XCTAssertEqual(backdropOpacity(translation: 300, height: 1_000), 0.5, accuracy: 0.001)
        XCTAssertEqual(backdropOpacity(translation: 600, height: 1_000), 0.15, accuracy: 0.001)
        XCTAssertEqual(backdropOpacity(translation: 5_000, height: 1_000), 0.15, accuracy: 0.001)
    }

    func testBackdropStaysOpaqueForUpwardDragsAndZeroHeight() {
        XCTAssertEqual(backdropOpacity(translation: -300, height: 1_000), 1, accuracy: 0.001)
        XCTAssertEqual(backdropOpacity(translation: 300, height: 0), 1, accuracy: 0.001)
    }

    func testUpwardDragOffsetIsDamped() {
        XCTAssertEqual(dismissDragOffset(translation: 100), 100, accuracy: 0.001)
        XCTAssertEqual(dismissDragOffset(translation: 0), 0, accuracy: 0.001)
        XCTAssertEqual(dismissDragOffset(translation: -100), -25, accuracy: 0.001)
    }

    func testDismissDragRectIsUnchangedAtRest() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let fitted = CGRect(x: 0, y: 250, width: 400, height: 300)

        XCTAssertEqual(dismissDragRect(fitting: fitted, in: bounds, translation: 0, reduceMotion: false), fitted)
    }

    func testDismissDragRectScalesAboutTheCenterAndFollowsTheDrag() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let fitted = CGRect(x: 0, y: 250, width: 400, height: 300)

        let rect = dismissDragRect(fitting: fitted, in: bounds, translation: 400, reduceMotion: false)

        XCTAssertEqual(rect.width, 400 * 0.825, accuracy: 0.001)
        XCTAssertEqual(rect.height, 300 * 0.825, accuracy: 0.001)
        XCTAssertEqual(rect.midX, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(rect.midY, fitted.midY + 400, accuracy: 0.001)
    }

    func testDismissDragRectOnlyMovesWithReduceMotion() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let fitted = CGRect(x: 0, y: 250, width: 400, height: 300)

        let rect = dismissDragRect(fitting: fitted, in: bounds, translation: 400, reduceMotion: true)

        XCTAssertEqual(rect, fitted.offsetBy(dx: 0, dy: 400))
    }

    func testDismissDragRectDampsUpwardDragWithoutScaling() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        let fitted = CGRect(x: 0, y: 250, width: 400, height: 300)

        let rect = dismissDragRect(fitting: fitted, in: bounds, translation: -200, reduceMotion: false)

        XCTAssertEqual(rect, fitted.offsetBy(dx: 0, dy: -50))
    }

    func testZoomEndpointsResolveAgainstTheViewerFrame() {
        let viewerFrame = CGRect(x: 0, y: 59, width: 400, height: 760)
        let imageSize = CGSize(width: 800, height: 600)

        XCTAssertEqual(
            ViewerZoomEndpoint.window(CGRect(x: 20, y: 200, width: 120, height: 120))
                .rect(imageSize: imageSize, viewerFrame: viewerFrame),
            CGRect(x: 20, y: 141, width: 120, height: 120)
        )
        XCTAssertEqual(
            ViewerZoomEndpoint.viewer(CGRect(x: 5, y: 6, width: 7, height: 8))
                .rect(imageSize: imageSize, viewerFrame: viewerFrame),
            CGRect(x: 5, y: 6, width: 7, height: 8)
        )
        XCTAssertEqual(
            ViewerZoomEndpoint.fitted.rect(imageSize: imageSize, viewerFrame: viewerFrame),
            CGRect(x: 0, y: 230, width: 400, height: 300)
        )
    }

    func testUnobscuredViewportRemovesTheBarInsets() {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)

        XCTAssertEqual(
            unobscuredViewport(frame: frame, topInset: 200, bottomInset: 83),
            CGRect(x: 0, y: 200, width: 390, height: 561)
        )
        XCTAssertEqual(unobscuredViewport(frame: frame, topInset: 0, bottomInset: 0), frame)
    }

    func testUnobscuredViewportNeverHasNegativeHeight() {
        let viewport = unobscuredViewport(
            frame: CGRect(x: 0, y: 100, width: 390, height: 100),
            topInset: 80,
            bottomInset: 80
        )

        XCTAssertEqual(viewport.height, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.minY, 180, accuracy: 0.001)
    }

    func testUnobscuredViewportIgnoresNegativeInsets() {
        let frame = CGRect(x: 0, y: 100, width: 390, height: 600)

        XCTAssertEqual(unobscuredViewport(frame: frame, topInset: -20, bottomInset: -20), frame)
    }

    func testTileInsideTheViewportIsLandable() {
        let viewport = CGRect(x: 0, y: 200, width: 390, height: 561)

        XCTAssertTrue(isLandableTileFrame(CGRect(x: 24, y: 300, width: 110, height: 110), viewport: viewport))
        XCTAssertTrue(isLandableTileFrame(CGRect(x: 24, y: 199.5, width: 110, height: 110), viewport: viewport))
    }

    func testTilePartlyUnderABarIsNotLandable() {
        let viewport = CGRect(x: 0, y: 200, width: 390, height: 561)

        XCTAssertFalse(isLandableTileFrame(CGRect(x: 24, y: 150, width: 110, height: 110), viewport: viewport))
        XCTAssertFalse(isLandableTileFrame(CGRect(x: 24, y: 700, width: 110, height: 110), viewport: viewport))
        XCTAssertFalse(isLandableTileFrame(CGRect(x: 24, y: 900, width: 110, height: 110), viewport: viewport))
    }

    func testTileIsLandableWhenTheViewportIsUnknown() {
        XCTAssertTrue(isLandableTileFrame(CGRect(x: 24, y: 150, width: 110, height: 110), viewport: nil))
    }

    func testTileFramesStoreReplaceAndRemoveFrames() {
        let tileFrames = MediaTileFrames()
        let mediaID = UUID()
        let otherID = UUID()

        XCTAssertNil(tileFrames.frame(for: mediaID))

        tileFrames.set(CGRect(x: 0, y: 0, width: 100, height: 100), for: mediaID)
        tileFrames.set(CGRect(x: 0, y: 120, width: 100, height: 100), for: mediaID)
        tileFrames.set(CGRect(x: 120, y: 0, width: 100, height: 100), for: otherID)

        XCTAssertEqual(tileFrames.frame(for: mediaID), CGRect(x: 0, y: 120, width: 100, height: 100))

        tileFrames.remove(mediaID)

        XCTAssertNil(tileFrames.frame(for: mediaID))
        XCTAssertEqual(tileFrames.frame(for: otherID), CGRect(x: 120, y: 0, width: 100, height: 100))
    }

    func testTileFramesStartWithoutAViewport() {
        let tileFrames = MediaTileFrames()

        XCTAssertNil(tileFrames.viewport)

        tileFrames.viewport = CGRect(x: 0, y: 200, width: 390, height: 561)

        XCTAssertEqual(tileFrames.viewport, CGRect(x: 0, y: 200, width: 390, height: 561))
    }
}
