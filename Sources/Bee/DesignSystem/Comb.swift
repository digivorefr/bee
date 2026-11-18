import SwiftUI

// The cell is Bee's one mark: a hexagon standing on a point, as in a comb. It says how an exchange
// turned out (a capped cell), which environment is live (a cell of honey), and it fills the empty
// response page as a comb that honey flows through while a request is in flight.

nonisolated enum CellGeometry {
    /// A hexagon standing on a point.
    static func path(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        for corner in 0..<6 {
            let angle = (CGFloat(corner) * 60 - 90) * .pi / 180
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Horizontal and vertical distance between neighbouring cells of a comb.
    static func step(radius: CGFloat) -> CGSize {
        CGSize(width: 3.squareRoot() * radius, height: 1.5 * radius)
    }
}

/// A hexagon standing on a point, as large as its frame allows.
nonisolated struct CellShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 3.squareRoot(), rect.height / 2)
        return CellGeometry.path(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius)
    }
}

/// A capped cell: filled with a color, with an optional glyph cut in the color of the paper.
/// Decorative by itself; the view that uses it says what it means in words.
struct CellMark: View {
    private let glyph: String?
    private let color: Color
    private let size: CGFloat
    private let isHollow: Bool

    /// - Parameters:
    ///   - size: the size of the text the mark sits beside.
    ///   - isHollow: an empty cell, drawn by its wall only: what is not the real thing yet (a fork).
    init(_ glyph: String? = nil, color: Color, size: CGFloat = Theme.Size.body, isHollow: Bool = false) {
        self.glyph = glyph
        self.color = color
        self.size = size
        self.isHollow = isHollow
    }

    var body: some View {
        let side = (size * 1.3).rounded()
        // The stroke rounds the corners; the padding keeps it inside the frame.
        let edge = side * (isHollow ? 0.14 : 0.12)
        ZStack {
            CellShape()
                .fill(isHollow ? Color.clear : color)
                .overlay(CellShape().stroke(color, style: StrokeStyle(lineWidth: edge, lineJoin: .round)))
                .padding(edge / 2)
            if let glyph {
                Image(systemName: glyph)
                    .font(.system(size: side * 0.46, weight: .heavy))
                    .foregroundStyle(Theme.paper)
            }
        }
        .frame(width: side, height: side)
        // Beside a line of text, the cell stands on the line like a capital with a short descender.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - $0.height * 0.2 }
        .accessibilityHidden(true)
    }
}

/// A comb drawn as a watermark from the bottom trailing corner of an empty page, fading toward the
/// text. While a request is in flight, honey flows through it from that corner.
struct CombField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the request left; `nil` at rest.
    var flowingSince: Date?

    private static let cellRadius: CGFloat = 21
    /// How far from the corner the comb reaches before it has faded out.
    private static let reach: CGFloat = 470
    /// Points per second of the honey front.
    private static let flowSpeed: CGFloat = 260
    private static let bandWidth: CGFloat = 150

    var body: some View {
        Group {
            if let flowingSince, !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    comb(elapsed: max(timeline.date.timeIntervalSince(flowingSince), 0))
                }
            } else {
                comb(elapsed: nil)
            }
        }
        .frame(maxWidth: Self.reach, maxHeight: Self.reach)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func comb(elapsed: TimeInterval?) -> some View {
        Canvas { context, size in
            let radius = Self.cellRadius
            let pitch = CellGeometry.step(radius: radius)
            let rows = Int(Self.reach / pitch.height) + 2
            let columns = Int(Self.reach / pitch.width) + 2
            let front = elapsed.map { CGFloat($0) * Self.flowSpeed }
                .map { $0.truncatingRemainder(dividingBy: Self.reach + Self.bandWidth) }

            for row in 0..<rows {
                for column in 0..<columns {
                    let shift = row.isMultiple(of: 2) ? 0 : pitch.width / 2
                    let center = CGPoint(
                        x: size.width - CGFloat(column) * pitch.width - shift + pitch.width * 0.2,
                        y: size.height - CGFloat(row) * pitch.height + radius * 0.25
                    )
                    let distance = hypot(size.width - center.x, size.height - center.y)
                    let presence = pow(max(0, 1 - distance / Self.reach), 1.5)
                    guard presence > 0.015 else { continue }

                    var honey: CGFloat = Self.isCapped(row: row, column: column) ? 0.7 : 0
                    if let front {
                        honey = max(honey, max(0, 1 - abs(distance - front) / Self.bandWidth))
                    }
                    let path = CellGeometry.path(center: center, radius: radius * 0.86)
                    let wall = StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                    if honey > 0 {
                        context.fill(path, with: .color(Theme.honey.opacity(honey * presence)))
                        context.stroke(path, with: .color(Theme.honey.opacity(honey * presence)), style: wall)
                    }
                    context.stroke(path, with: .color(Theme.outline.opacity(0.5 * presence * (1 - honey))), style: wall)
                }
            }
        }
    }

    /// The few cells that hold honey at rest, the same on every page.
    private static func isCapped(row: Int, column: Int) -> Bool {
        (row * 31 + column * 17 + row * column * 3) % 9 == 4
    }
}

/// A small cluster of seven cells that stands for a request in flight: honey goes round the ring.
struct CombSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = Theme.Size.headline

    var body: some View {
        let height = (size * 1.45).rounded()
        Group {
            if reduceMotion {
                cluster(phase: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    cluster(phase: timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2)
                }
            }
        }
        .frame(width: (height * 3 * 3.squareRoot() / 5).rounded(.up), height: height)
        .accessibilityHidden(true)
    }

    private func cluster(phase: Double?) -> some View {
        Canvas { context, size in
            // Three cells wide, five radii tall.
            let radius = min(size.height / 5, size.width / (3 * 3.squareRoot()))
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            let spacing = 3.squareRoot() * radius
            context.fill(CellGeometry.path(center: middle, radius: radius * 0.84), with: .color(Theme.honey))
            for cell in 0..<6 {
                let angle = CGFloat(cell) * .pi / 3
                let center = CGPoint(x: middle.x + spacing * cos(angle), y: middle.y + spacing * sin(angle))
                var strength = 0.45
                if let phase {
                    let lag = (phase - Double(cell) / 6 + 1).truncatingRemainder(dividingBy: 1)
                    strength = 0.15 + 0.85 * max(0, 1 - lag * 1.6)
                }
                context.fill(
                    CellGeometry.path(center: center, radius: radius * 0.84),
                    with: .color(Theme.honey.opacity(strength))
                )
            }
        }
    }
}
