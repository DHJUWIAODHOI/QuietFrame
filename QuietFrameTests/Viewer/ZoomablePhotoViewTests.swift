import UIKit
import XCTest
@testable import QuietFrame

@MainActor
final class ZoomablePhotoViewTests: XCTestCase {
    func testImageIsFittedAndCenteredAtMinimumZoom() {
        var reportedZoomStates: [Bool] = []
        let coordinator = ZoomablePhotoView.Coordinator { reportedZoomStates.append($0) }
        let scrollView = makeScrollView(coordinator: coordinator)

        scrollView.display(makeImage(width: 1_000, height: 500))
        scrollView.layoutIfNeeded()

        XCTAssertEqual(scrollView.imageView.frame.width, 300, accuracy: 0.5)
        XCTAssertEqual(scrollView.imageView.frame.height, 150, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentSize.width, 300, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentSize.height, 150, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentInset.top, 225, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentInset.left, 0, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentOffset.y, -225, accuracy: 0.5)
        XCTAssertEqual(horizontalScrollRange(of: scrollView), 0, accuracy: 0.5)
        XCTAssertEqual(verticalScrollRange(of: scrollView), 0, accuracy: 0.5)
        XCTAssertEqual(reportedZoomStates, [])
        withExtendedLifetime(coordinator) {}
    }

    func testZoomedPhotoHasPannableRangeToEveryEdge() {
        var reportedZoomStates: [Bool] = []
        let coordinator = ZoomablePhotoView.Coordinator { reportedZoomStates.append($0) }
        let scrollView = makeScrollView(coordinator: coordinator)
        scrollView.display(makeImage(width: 1_000, height: 500))
        scrollView.layoutIfNeeded()

        scrollView.setZoomScale(3, animated: false)
        scrollView.layoutIfNeeded()

        XCTAssertEqual(scrollView.contentSize.width, 900, accuracy: 1)
        XCTAssertEqual(scrollView.contentSize.height, 450, accuracy: 1)
        XCTAssertEqual(scrollView.imageView.frame.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scrollView.imageView.frame.maxX, 900, accuracy: 1)
        XCTAssertEqual(scrollView.contentInset.top, 75, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentInset.left, 0, accuracy: 0.5)
        XCTAssertEqual(horizontalScrollRange(of: scrollView), 600, accuracy: 1)
        XCTAssertEqual(verticalScrollRange(of: scrollView), 0, accuracy: 1)
        XCTAssertEqual(reportedZoomStates, [true])

        // Layout passes while zoomed must not re-fit or re-center the user's pan position.
        scrollView.setContentOffset(CGPoint(x: 600, y: -75), animated: false)
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        XCTAssertEqual(scrollView.contentOffset.x, 600, accuracy: 0.5)
        XCTAssertEqual(scrollView.zoomScale, 3, accuracy: 0.001)
        withExtendedLifetime(coordinator) {}
    }

    func testFittedImageNeverOvershootsTheViewport() {
        let coordinator = ZoomablePhotoView.Coordinator { _ in }
        let scrollView = makeScrollView(coordinator: coordinator)
        // 3024 * (393 / 3024) rounds to 393.00000000000006, so each orientation exercises one clamp.
        let image = makeImage(width: 3_024, height: 3_024)

        scrollView.frame = CGRect(x: 0, y: 0, width: 393, height: 759)
        scrollView.display(image)
        scrollView.layoutIfNeeded()
        XCTAssertLessThanOrEqual(
            scrollView.contentSize.width + scrollView.contentInset.left + scrollView.contentInset.right,
            scrollView.bounds.width
        )

        scrollView.frame = CGRect(x: 0, y: 0, width: 759, height: 393)
        scrollView.layoutIfNeeded()
        XCTAssertLessThanOrEqual(
            scrollView.contentSize.height + scrollView.contentInset.top + scrollView.contentInset.bottom,
            scrollView.bounds.height
        )
        withExtendedLifetime(coordinator) {}
    }

    func testImageDisplayedBeforeLayoutIsFittedOnceSized() {
        let coordinator = ZoomablePhotoView.Coordinator { _ in }
        let scrollView = makeScrollView(coordinator: coordinator, frame: .zero)

        scrollView.display(makeImage(width: 1_000, height: 500))
        scrollView.frame = CGRect(x: 0, y: 0, width: 300, height: 600)
        scrollView.layoutIfNeeded()

        XCTAssertEqual(scrollView.imageView.frame.width, 300, accuracy: 0.5)
        XCTAssertEqual(scrollView.imageView.frame.height, 150, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentInset.top, 225, accuracy: 0.5)
        withExtendedLifetime(coordinator) {}
    }

    func testBoundsChangeRefitsAtMinimumZoomButKeepsActiveZoom() {
        let coordinator = ZoomablePhotoView.Coordinator { _ in }
        let scrollView = makeScrollView(coordinator: coordinator)
        scrollView.display(makeImage(width: 1_000, height: 500))
        scrollView.layoutIfNeeded()

        scrollView.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        scrollView.layoutIfNeeded()
        XCTAssertEqual(scrollView.imageView.frame.width, 600, accuracy: 0.5)
        XCTAssertEqual(scrollView.imageView.frame.height, 300, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentInset.top, 0, accuracy: 0.5)

        scrollView.setZoomScale(2, animated: false)
        scrollView.frame = CGRect(x: 0, y: 0, width: 600, height: 280)
        scrollView.layoutIfNeeded()
        XCTAssertEqual(scrollView.zoomScale, 2, accuracy: 0.001)

        scrollView.setZoomScale(1, animated: false)
        scrollView.setNeedsLayout()
        scrollView.layoutIfNeeded()
        XCTAssertEqual(scrollView.imageView.frame.width, 560, accuracy: 0.5)
        XCTAssertEqual(scrollView.imageView.frame.height, 280, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentInset.left, 20, accuracy: 0.5)
        withExtendedLifetime(coordinator) {}
    }

    func testZoomEndRequestsLayoutSoDeferredRefitRuns() {
        let coordinator = ZoomablePhotoView.Coordinator { _ in }
        let scrollView = makeScrollView(coordinator: coordinator)
        scrollView.display(makeImage(width: 1_000, height: 500))
        scrollView.layoutIfNeeded()
        XCTAssertFalse(scrollView.layer.needsLayout())

        coordinator.scrollViewDidEndZooming(scrollView, with: scrollView.imageView, atScale: 1)

        XCTAssertTrue(scrollView.layer.needsLayout())
        withExtendedLifetime(coordinator) {}
    }

    private func makeScrollView(
        coordinator: ZoomablePhotoView.Coordinator,
        frame: CGRect = CGRect(x: 0, y: 0, width: 300, height: 600)
    ) -> ZoomingImageScrollView {
        let scrollView = ZoomingImageScrollView(frame: frame)
        scrollView.delegate = coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.contentInsetAdjustmentBehavior = .never
        coordinator.scrollView = scrollView
        return scrollView
    }

    private func horizontalScrollRange(of scrollView: UIScrollView) -> CGFloat {
        scrollView.contentSize.width + scrollView.contentInset.left + scrollView.contentInset.right
            - scrollView.bounds.width
    }

    private func verticalScrollRange(of scrollView: UIScrollView) -> CGFloat {
        scrollView.contentSize.height + scrollView.contentInset.top + scrollView.contentInset.bottom
            - scrollView.bounds.height
    }

    private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }
}
