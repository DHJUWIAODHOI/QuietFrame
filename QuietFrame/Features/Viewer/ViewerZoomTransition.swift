import SwiftUI
import UIKit

/// Window frames of the gallery tiles currently on screen, so the viewer can open from and return to a tile.
/// Tiles report frames in the grid's own coordinate space, which scrolling leaves unchanged, and a single reporter
/// tracks where the grid sits in the window. Deliberately not observable, so reporting re-renders nothing.
@MainActor
final class MediaTileFrames {
    private var frames: [UUID: CGRect] = [:]
    /// Where the grid's coordinate space starts in the window; it moves as the grid scrolls.
    var contentOrigin: CGPoint = .zero
    /// The window rect where the grid's tiles are visible, outside the navigation, filter and tab bars.
    var viewport: CGRect?

    func set(_ frame: CGRect, for mediaID: UUID) {
        frames[mediaID] = frame
    }

    func remove(_ mediaID: UUID) {
        frames[mediaID] = nil
    }

    func frame(for mediaID: UUID) -> CGRect? {
        frames[mediaID]?.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
    }
}

/// The part of a scroll view's window frame that is not covered by the bars insetting its safe area.
func unobscuredViewport(frame: CGRect, topInset: CGFloat, bottomInset: CGFloat) -> CGRect {
    let top = max(topInset, 0)
    let bottom = max(bottomInset, 0)
    return CGRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: max(frame.height - top - bottom, 0))
}

/// Whether a returning photo can land on a tile without covering a bar: the tile lies wholly inside the viewport.
func isLandableTileFrame(_ frame: CGRect, viewport: CGRect?) -> Bool {
    guard let viewport else { return true }
    return viewport.insetBy(dx: -1, dy: -1).contains(frame)
}

/// The rect an image of `imageSize` occupies when scaled to fit and centred in `bounds`.
func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let width = min(bounds.width, imageSize.width * scale)
    let height = min(bounds.height, imageSize.height * scale)
    return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
}

/// How far a dismiss drag has pulled the media down, from 0 at rest to 1 at a full viewer height.
func dismissProgress(translation: CGFloat, height: CGFloat) -> CGFloat {
    guard height > 0 else { return 0 }
    return min(max(translation, 0) / height, 1)
}

func dragScale(progress: CGFloat, reduceMotion: Bool) -> CGFloat {
    guard !reduceMotion else { return 1 }
    return 1 - 0.35 * min(max(progress, 0), 1)
}

func shouldDismiss(translation: CGFloat, velocity: CGFloat) -> Bool {
    translation > 120 || (translation > 12 && velocity > 400)
}

func backdropOpacity(translation: CGFloat, height: CGFloat) -> Double {
    guard height > 0 else { return 1 }
    return Double(1 - min(max(translation, 0) / (height * 0.6), 0.85))
}

/// Upward drags are damped so the media resists being pushed away from a dismissal.
func dismissDragOffset(translation: CGFloat) -> CGFloat {
    translation > 0 ? translation : translation * 0.25
}

/// Where `rect` is drawn while a dismiss drag scales the viewer content about its centre and moves it down.
func dismissDragRect(fitting rect: CGRect, in bounds: CGRect, translation: CGFloat, reduceMotion: Bool) -> CGRect {
    let progress = dismissProgress(translation: translation, height: bounds.height)
    let scale = dragScale(progress: progress, reduceMotion: reduceMotion)
    let offset = dismissDragOffset(translation: translation)
    return CGRect(
        x: bounds.midX + (rect.minX - bounds.midX) * scale,
        y: bounds.midY + (rect.minY - bounds.midY) * scale + offset,
        width: rect.width * scale,
        height: rect.height * scale
    )
}

enum ViewerZoomMotion {
    static let openDuration: TimeInterval = 0.36
    static let returnDuration: TimeInterval = 0.3
    static let slideAwayDuration: TimeInterval = 0.25
    static let backdropDuration: TimeInterval = 0.24
    static let fadeDuration: TimeInterval = 0.2

    static func drawer(duration: TimeInterval) -> Animation {
        .timingCurve(0.32, 0.72, 0, 1, duration: duration)
    }

    static func easeOut(duration: TimeInterval) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}

/// One end of a zoom flight, resolved against the viewer's frame in the window when it is drawn.
enum ViewerZoomEndpoint: Equatable {
    case window(CGRect)
    case viewer(CGRect)
    case fitted

    func rect(imageSize: CGSize, viewerFrame: CGRect) -> CGRect {
        switch self {
        case .window(let frame):
            return frame.offsetBy(dx: -viewerFrame.minX, dy: -viewerFrame.minY)
        case .viewer(let frame):
            return frame
        case .fitted:
            return aspectFitRect(imageSize: imageSize, in: CGRect(origin: .zero, size: viewerFrame.size))
        }
    }
}

struct ViewerZoomFlight: Identifiable {
    enum Purpose {
        case opening
        case closing
    }

    let id = UUID()
    let purpose: Purpose
    var image: UIImage
    let from: ViewerZoomEndpoint
    let to: ViewerZoomEndpoint
    let fromCornerRadius: CGFloat
    let toCornerRadius: CGFloat
    var fadesOut = false
    let duration: TimeInterval
    let animation: Animation
}

/// The media image flying between its gallery tile and its place in the viewer.
struct ViewerZoomFlyer: View {
    let image: UIImage
    let from: CGRect
    let to: CGRect
    let fromCornerRadius: CGFloat
    let toCornerRadius: CGFloat
    let fadesOut: Bool
    let animation: Animation
    let onArrival: () -> Void

    @State private var hasArrived = false

    var body: some View {
        let rect = hasArrived ? to : from
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(
                cornerRadius: hasArrived ? toCornerRadius : fromCornerRadius,
                style: .continuous
            ))
            .opacity(fadesOut && hasArrived ? 0 : 1)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(animation) {
                    hasArrived = true
                } completion: {
                    onArrival()
                }
            }
    }
}
