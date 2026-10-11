import SwiftUI

/// One iris blade in a 200 x 200 design space centered on (100, 100).
/// `closure` morphs the blade from fully open (0) through half closed (0.5) to shut (1).
struct ApertureBladeShape: Shape {
    var closure: CGFloat

    var animatableData: CGFloat {
        get { closure }
        set { closure = newValue }
    }

    private struct Keyframe {
        let inner: CGPoint
        let edge: CGPoint
        let leadingControl: CGPoint
        let arcStart: CGPoint
        let arcEnd: CGPoint
        let trailingControl: CGPoint
    }

    private static let open = Keyframe(
        inner: CGPoint(x: 70.27, y: 52.54),
        edge: CGPoint(x: 126.24, y: 50.53),
        leadingControl: CGPoint(x: 148.94, y: 49.71),
        arcStart: CGPoint(x: 133.67, y: 18.7),
        arcEnd: CGPoint(x: 46.42, y: 30.19),
        trailingControl: CGPoint(x: 80.92, y: 32.47)
    )

    private static let half = Keyframe(
        inner: CGPoint(x: 76.68, y: 75.25),
        edge: CGPoint(x: 109.77, y: 67.43),
        leadingControl: CGPoint(x: 141.85, y: 59.85),
        arcStart: CGPoint(x: 137.41, y: 20.35),
        arcEnd: CGPoint(x: 49.72, y: 27.78),
        trailingControl: CGPoint(x: 86.16, y: 43.68)
    )

    private static let closed = Keyframe(
        inner: CGPoint(x: 100, y: 100),
        edge: CGPoint(x: 100, y: 100),
        leadingControl: CGPoint(x: 135.86, y: 74.5),
        arcStart: CGPoint(x: 133.79, y: 18.74),
        arcEnd: CGPoint(x: 46.52, y: 30.11),
        trailingControl: CGPoint(x: 95.84, y: 56.2)
    )

    private static let center = CGPoint(x: 100, y: 100)
    private static let radius: CGFloat = 88

    func path(in rect: CGRect) -> Path {
        let frame = Self.keyframe(at: min(max(closure, 0), 1))
        let side = min(rect.width, rect.height)
        let scale = side / 200
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
        }

        var path = Path()
        path.move(to: map(frame.inner))
        path.addLine(to: map(frame.edge))
        path.addQuadCurve(to: map(frame.arcStart), control: map(frame.leadingControl))

        let startAngle = atan2(frame.arcStart.y - Self.center.y, frame.arcStart.x - Self.center.x)
        let endAngle = atan2(frame.arcEnd.y - Self.center.y, frame.arcEnd.x - Self.center.x)
        var sweep = endAngle - startAngle
        if sweep > .pi { sweep -= 2 * .pi }
        if sweep < -.pi { sweep += 2 * .pi }
        let steps = 24
        for step in 1...steps {
            let angle = startAngle + sweep * CGFloat(step) / CGFloat(steps)
            path.addLine(to: map(CGPoint(
                x: Self.center.x + Self.radius * cos(angle),
                y: Self.center.y + Self.radius * sin(angle)
            )))
        }

        path.addQuadCurve(to: map(frame.inner), control: map(frame.trailingControl))
        path.closeSubpath()
        return path
    }

    private static func keyframe(at closure: CGFloat) -> Keyframe {
        if closure <= 0.5 {
            return interpolate(open, half, closure / 0.5)
        }
        return interpolate(half, closed, (closure - 0.5) / 0.5)
    }

    private static func interpolate(_ from: Keyframe, _ to: Keyframe, _ progress: CGFloat) -> Keyframe {
        func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
        }
        return Keyframe(
            inner: mix(from.inner, to.inner),
            edge: mix(from.edge, to.edge),
            leadingControl: mix(from.leadingControl, to.leadingControl),
            arcStart: mix(from.arcStart, to.arcStart),
            arcEnd: mix(from.arcEnd, to.arcEnd),
            trailingControl: mix(from.trailingControl, to.trailingControl)
        )
    }
}

/// The six-blade aperture: Aperture's signature. Filled blades take `fillColor` (brass by default)
/// with night seams; empty blades are dusk outlined in mist. Callers either label it or hide it from accessibility.
struct ApertureIris: View {
    var closure: CGFloat
    var filledBlades: Int
    var size: CGFloat = 192
    var showsRing = true
    var fillColor: Color = QuietFrameTheme.accent

    var body: some View {
        let scale = size / 200
        ZStack {
            if showsRing {
                Circle()
                    .inset(by: 4 * scale)
                    .stroke(QuietFrameTheme.slate, lineWidth: 2 * scale)
            }
            ForEach(0..<6, id: \.self) { index in
                let isFilled = index < filledBlades
                ApertureBladeShape(closure: closure)
                    .fill(isFilled ? fillColor : QuietFrameTheme.elevated)
                    .overlay {
                        ApertureBladeShape(closure: closure)
                            .stroke(
                                isFilled ? QuietFrameTheme.background : QuietFrameTheme.quietInk,
                                style: StrokeStyle(lineWidth: (isFilled ? 2.5 : 1.5) * scale, lineJoin: .round)
                            )
                    }
                    .rotationEffect(.degrees(Double(index) * 60))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The QuietFrame mark: an iris framed by viewfinder corners, as on Welcome and the privacy cover.
struct ApertureMark: View {
    var closure: CGFloat
    var filledBlades: Int
    var size: CGFloat = 176

    var body: some View {
        let scale = size / 200
        ZStack {
            ViewfinderCorners()
                .stroke(
                    QuietFrameTheme.quietInk,
                    style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round, lineJoin: .round)
                )
                .frame(width: size + 24 * scale, height: size + 24 * scale)
            ApertureIris(closure: closure, filledBlades: filledBlades, size: size)
        }
        .frame(width: size + 28 * scale, height: size + 28 * scale)
        .accessibilityHidden(true)
    }
}

/// Four rounded viewfinder brackets at the corners of the rect.
struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.125
        let radius = length * 0.36
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        return path
    }
}
