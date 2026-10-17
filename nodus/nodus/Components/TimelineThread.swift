import SwiftUI

struct TimelineThread: Shape {
    var knotFractions: [CGFloat] = []
    var lostKnotFractions: [CGFloat] = []

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let knots = knotFractions + lostKnotFractions
        let fractions = knots.map { min(max($0, 0), 1) }.sorted()
        var currentY = rect.minY

        path.move(to: point(in: rect, atY: currentY))

        for fraction in fractions {
            let knotY = rect.minY + rect.height * fraction
            let startY = max(rect.minY, knotY - 16)
            let endY = min(rect.maxY, knotY + 16)

            addThreadSegment(to: &path, in: rect, from: currentY, to: startY)
            addKnot(to: &path, in: rect, centerY: knotY, startY: startY, endY: endY)

            currentY = endY
        }

        addThreadSegment(to: &path, in: rect, from: currentY, to: rect.maxY)

        return path
    }

    private func addThreadSegment(to path: inout Path, in rect: CGRect, from startY: CGFloat, to endY: CGFloat) {
        guard endY > startY else { return }

        // Densely sample the shared curve so compact fragments retain the
        // same smooth appearance as the longer thread on the home screen.
        let steps = max(Int((endY - startY) / 2), 1)
        for step in 1...steps {
            let y = startY + (endY - startY) * CGFloat(step) / CGFloat(steps)
            path.addLine(to: point(in: rect, atY: y))
        }
    }

    /// A rope-like loop tied into the thread: curvature tightens gradually
    /// (a wide bend, then tighter, then the loop loop) rather than
    /// jumping straight from a flat line into a tight circle, so the line
    /// flows into the loop the way an actual cord would.
    ///
    /// The thread itself leans left/right as it curves (`xOffset`), so the
    /// knot must start from whatever direction the thread is actually
    /// heading at this point — not assume it's perfectly vertical — or the
    /// straight segment leading in visibly kinks where it meets the loop.
    private func addKnot(to path: inout Path, in rect: CGRect, centerY: CGFloat, startY: CGFloat, endY: CGFloat) {
        let end = point(in: rect, atY: endY)

        let span = endY - startY
        var p = point(in: rect, atY: startY)
        var heading = tangentHeading(in: rect, atY: startY)

        path.addLine(to: p)

        let arcs: [(radius: CGFloat, turnDegrees: CGFloat)] = [
            (span * 0.469, 32),
            (span * 0.281, 38),
            (span * 0.150, 110),
            (span * 0.150, 110),
            (span * 0.281, 38),
            (span * 0.469, 32)
        ]

        for arc in arcs {
            (p, heading) = addArc(to: &path, from: p, heading: heading, radius: arc.radius, turnDegrees: arc.turnDegrees)
        }

        path.addLine(to: end)
    }

    /// Appends one circular arc starting at `from` with the given heading
    /// (radians, screen convention where 0 = +x and increasing turns
    /// clockwise), turning by `turnDegrees` (positive curves to the left of
    /// the direction of travel). Returns the arc's end point and heading.
    private func addArc(to path: inout Path, from: CGPoint, heading: CGFloat, radius: CGFloat, turnDegrees: CGFloat) -> (CGPoint, CGFloat) {
        let turn = turnDegrees * .pi / 180
        let startAngle = heading - .pi / 2
        let center = CGPoint(x: from.x - radius * cos(startAngle), y: from.y - radius * sin(startAngle))

        let steps = max(Int(abs(turnDegrees) / 3), 8)
        for step in 1...steps {
            let angle = startAngle + turn * CGFloat(step) / CGFloat(steps)
            path.addLine(to: CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle)))
        }

        let endAngle = startAngle + turn
        let endPoint = CGPoint(x: center.x + radius * cos(endAngle), y: center.y + radius * sin(endAngle))
        return (endPoint, heading + turn)
    }

    private func point(in rect: CGRect, atY y: CGFloat) -> CGPoint {
        CGPoint(x: x(in: rect, atY: y), y: y)
    }

    private func x(in rect: CGRect, atY y: CGFloat) -> CGFloat {
        let fraction = rect.height > 0 ? (y - rect.minY) / rect.height : 0
        return rect.midX + Self.xOffset(at: fraction)
    }

    /// The thread's direction of travel at a given y, expressed the same
    /// way `addArc` does (`.pi/2` = straight down), derived from the local
    /// slope of `xOffset` rather than assumed to be vertical.
    private func tangentHeading(in rect: CGRect, atY y: CGFloat) -> CGFloat {
        guard rect.height > 0 else { return .pi / 2 }
        let epsilon: CGFloat = 1
        let slope = (x(in: rect, atY: y + epsilon) - x(in: rect, atY: y - epsilon)) / (2 * epsilon)
        return atan2(1, slope)
    }

    /// Horizontal deviation from the thread's center axis at a given vertical
    /// fraction (0...1), matching the cubic segments drawn in `path(in:)`.
    static func xOffset(at t: CGFloat) -> CGFloat {
        let segments: [(start: CGFloat, end: CGFloat, p0: CGFloat, c1: CGFloat, c2: CGFloat, p1: CGFloat)] = [
            (0.00, 0.26, 0, -5, 7, 4),
            (0.26, 0.53, 4, 1, -7, -3),
            (0.53, 0.78, -3, 2, 6, 2),
            (0.78, 1.00, 2, -3, 0, 0)
        ]

        let clamped = min(max(t, 0), 1)
        let segment = segments.first { clamped <= $0.end } ?? segments[segments.count - 1]
        let span = segment.end - segment.start
        let u = span > 0 ? min(max((clamped - segment.start) / span, 0), 1) : 0
        let inverse = 1 - u

        return inverse * inverse * inverse * segment.p0
            + 3 * inverse * inverse * u * segment.c1
            + 3 * inverse * u * u * segment.c2
            + u * u * u * segment.p1
    }
}
