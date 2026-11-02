import SwiftUI
import UIKit

struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage
    let accessibilityLabel: String
    let onZoomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onZoomChanged: onZoomChanged)
    }

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let scrollView = ZoomingImageScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = QuietFrameTheme.nightUI

        let imageView = scrollView.imageView
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: ZoomingImageScrollView, context: Context) {
        context.coordinator.onZoomChanged = onZoomChanged
        scrollView.display(image)
        scrollView.imageView.accessibilityLabel = accessibilityLabel
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: ZoomingImageScrollView?
        var onZoomChanged: (Bool) -> Void
        private var reportedIsZoomed = false

        init(onZoomChanged: @escaping (Bool) -> Void) {
            self.onZoomChanged = onZoomChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomingImageScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomingImageScrollView)?.centerImage()
            let isZoomed = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01
            guard reportedIsZoomed != isZoomed else { return }
            reportedIsZoomed = isZoomed
            onZoomChanged(isZoomed)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            // A size change that arrived while zoomed is applied once the zoom settles at minimum scale.
            scrollView.setNeedsLayout()
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            // Respect Reduce Motion without changing zoom targets.
            let animated = !UIAccessibility.isReduceMotionEnabled
            if scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: animated)
                return
            }

            let imageBounds = scrollView.imageView.bounds
            let location = recognizer.location(in: scrollView.imageView)
            let point = CGPoint(
                x: min(max(location.x, imageBounds.minX), imageBounds.maxX),
                y: min(max(location.y, imageBounds.minY), imageBounds.maxY)
            )
            let targetScale = min(3, scrollView.maximumZoomScale)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            let rect = CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height
            )
            scrollView.zoom(to: rect, animated: animated)
        }
    }
}

/// Lays the image out at its aspect-fit size for zoom scale 1 and centers it with content insets,
/// so a zoomed image keeps a real content size and can be panned to every edge.
final class ZoomingImageScrollView: UIScrollView {
    let imageView = UIImageView()
    private var fittedBoundsSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(imageView)
    }

    func display(_ image: UIImage) {
        guard imageView.image !== image else { return }
        let previousSize = imageView.image?.size
        imageView.image = image
        // A sharper copy of the same photo arriving mid-zoom replaces it in place, keeping the zoom and position.
        if let previousSize, zoomScale > minimumZoomScale + 0.01, hasSameAspectRatio(previousSize, image.size) {
            return
        }
        fitImageToBounds()
    }

    private func hasSameAspectRatio(_ first: CGSize, _ second: CGSize) -> Bool {
        guard first.width > 0, first.height > 0, second.width > 0, second.height > 0 else { return false }
        return abs(first.width / first.height - second.width / second.height) <= 0.01 * (first.width / first.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isAtMinimumZoom = zoomScale <= minimumZoomScale + 0.01
        if bounds.size != fittedBoundsSize, isAtMinimumZoom, !isZooming, !isZoomBouncing {
            fitImageToBounds()
        } else {
            centerImage()
        }
    }

    func centerImage() {
        let horizontalInset = max(0, (bounds.width - contentSize.width) / 2)
        let verticalInset = max(0, (bounds.height - contentSize.height) / 2)
        let insets = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
        if contentInset != insets {
            contentInset = insets
        }
    }

    private func fitImageToBounds() {
        fittedBoundsSize = bounds.size
        if zoomScale != minimumZoomScale {
            zoomScale = minimumZoomScale
        }
        imageView.frame = CGRect(origin: .zero, size: fittedImageSize())
        contentSize = imageView.frame.size
        centerImage()
        contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
    }

    private func fittedImageSize() -> CGSize {
        guard let imageSize = imageView.image?.size,
              imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds.size }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        // Clamp so floating-point rounding can never make an unzoomed photo scrollable.
        return CGSize(
            width: min(bounds.width, imageSize.width * scale),
            height: min(bounds.height, imageSize.height * scale)
        )
    }
}
