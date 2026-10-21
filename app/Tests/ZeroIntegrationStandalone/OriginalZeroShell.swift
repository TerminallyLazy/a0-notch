// Frozen original shell-only drawing from pre-integration ZeroView (2026-10-20).
// A regression oracle, NOT a substitute for the real ZeroView under test.
import SwiftUI
@MainActor struct OriginalZeroShell: View {
    let stateTint: Color = .white
    var body: some View {
        Canvas { context, size in
            var c = context
            c.scaleBy(x: size.width / 100, y: size.height / 100)
            drawShell(in: c, detailed: true)
        }
    }
    private func drawShell(in context: GraphicsContext, detailed: Bool) {
        let shell = shellPath()
        context.fill(shell, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(hex: 0xFDFDFD), location: 0),
                .init(color: Color(hex: 0xE6E9EE), location: 0.48),
                .init(color: Color(hex: 0xAEB4BE), location: 1)
            ]),
            startPoint: CGPoint(x: 64, y: 22), endPoint: CGPoint(x: 36, y: 83)))

        var surface = context
        surface.clip(to: shell)
        surface.fill(shell, with: .linearGradient(
            Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.55),
                .init(color: stateTint.opacity(0.30), location: 1)
            ]),
            startPoint: CGPoint(x: 50, y: 24), endPoint: CGPoint(x: 50, y: 82)))

        // A colored ceramic edge, not an ambient neon halo.
        var rim = Path()
        rim.move(to: CGPoint(x: 22, y: 65))
        rim.addCurve(to: CGPoint(x: 79, y: 64),
                     control1: CGPoint(x: 27, y: 85), control2: CGPoint(x: 67, y: 86))
        surface.stroke(rim, with: .color(stateTint.opacity(0.85)),
                       style: StrokeStyle(lineWidth: detailed ? 2.8 : 3.8, lineCap: .round))
        context.stroke(shell, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.72), .white.opacity(0.08)]),
            startPoint: CGPoint(x: 65, y: 23), endPoint: CGPoint(x: 33, y: 80)),
            lineWidth: 0.8)

        if detailed {
            var highlight = Path()
            highlight.move(to: CGPoint(x: 34, y: 29))
            highlight.addQuadCurve(to: CGPoint(x: 66, y: 28), control: CGPoint(x: 51, y: 21))
            surface.stroke(highlight, with: .color(.white.opacity(0.62)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round))

            // A quiet pair of signal notches gives Zero a technical rather than toy-like finish.
            // It is decoration, not a substitute logo or a connection indicator.
            for index in 0..<2 {
                let mark = CGRect(x: 45 + CGFloat(index) * 5, y: 72, width: 2.5, height: 1.7)
                surface.fill(Path(roundedRect: mark, cornerRadius: 0.85),
                             with: .color(A0Theme.accent.opacity(0.8)))
            }
        }
    }

    private func shellPath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 48, y: 22))
        path.addCurve(to: CGPoint(x: 84, y: 49),
                      control1: CGPoint(x: 70, y: 18), control2: CGPoint(x: 82, y: 30))
        path.addCurve(to: CGPoint(x: 65, y: 79),
                      control1: CGPoint(x: 89, y: 68), control2: CGPoint(x: 80, y: 78))
        path.addCurve(to: CGPoint(x: 21, y: 68),
                      control1: CGPoint(x: 46, y: 83), control2: CGPoint(x: 26, y: 81))
        path.addCurve(to: CGPoint(x: 22, y: 36),
                      control1: CGPoint(x: 13, y: 55), control2: CGPoint(x: 14, y: 44))
        path.addCurve(to: CGPoint(x: 48, y: 22),
                      control1: CGPoint(x: 28, y: 28), control2: CGPoint(x: 37, y: 24))
        path.closeSubpath()
        return path
    }

}
