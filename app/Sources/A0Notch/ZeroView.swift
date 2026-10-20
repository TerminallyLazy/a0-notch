import SwiftUI

/// Original pebble companion, deliberately separate from the official Agent Zero marks.
struct ZeroView: View {
    let tint: Color
    var gaze: CGPoint = .zero
    var animated = true
    var happy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    character(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // No animation schedule at all for pips, paused views or Reduce Motion.
                // Input changes (including gaze and state color) can still redraw the Canvas.
                character(time: nil)
            }
        }
        .accessibilityHidden(true)
    }

    private func character(time: TimeInterval?) -> some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            guard side.isFinite, side > 0 else { return }
            let breath = time.map { sin($0 * 1.65) } ?? 0
            let gazeX = gaze.x.isFinite ? min(1, max(-1, gaze.x)) : 0
            let gazeY = gaze.y.isFinite ? min(1, max(-1, gaze.y)) : 0

            // A square design space preserves proportions in both tall cards and short bars.
            // Breathing is a sub-point lift at normal size, not a rubbery body deformation.
            context.translateBy(x: (size.width - side) / 2,
                                y: (size.height - side) / 2 - CGFloat(breath) * side * 0.006)
            context.scaleBy(x: side / 100, y: side / 100)
            drawShell(in: context, detailed: side >= 48)
            drawVisor(in: context, gaze: CGPoint(x: gazeX, y: gazeY),
                      openness: eyeOpenness(at: time), detailed: side >= 48)
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
                .init(color: tint.opacity(0.30), location: 1)
            ]),
            startPoint: CGPoint(x: 50, y: 24), endPoint: CGPoint(x: 50, y: 82)))

        // A colored ceramic edge, not an ambient neon halo.
        var rim = Path()
        rim.move(to: CGPoint(x: 22, y: 65))
        rim.addCurve(to: CGPoint(x: 79, y: 64),
                     control1: CGPoint(x: 27, y: 85), control2: CGPoint(x: 67, y: 86))
        surface.stroke(rim, with: .color(tint.opacity(0.85)),
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

    private func drawVisor(in context: GraphicsContext, gaze: CGPoint,
                           openness: CGFloat, detailed: Bool) {
        var face = context
        // A small face shift suggests looking around without rotating or stretching the shell.
        face.translateBy(x: gaze.x * 1.2, y: gaze.y * 0.8)
        let visor = visorPath()
        face.stroke(visor, with: .color(Color.black.opacity(0.28)), lineWidth: 2.2)
        face.fill(visor, with: .linearGradient(
            Gradient(colors: [A0Theme.messageBackground, A0Theme.background]),
            startPoint: CGPoint(x: 43, y: 35), endPoint: CGPoint(x: 57, y: 65)))
        face.stroke(visor, with: .linearGradient(
            Gradient(colors: [.black.opacity(0.55), .white.opacity(0.36)]),
            startPoint: CGPoint(x: 50, y: 35), endPoint: CGPoint(x: 50, y: 66)),
            lineWidth: 0.9)
        face.clip(to: visor)

        let eyeY: CGFloat = 49 + gaze.y * 2.3
        for index in 0..<2 {
            let eyeX: CGFloat = (index == 0 ? 41 : 61) + gaze.x * 3.2
            if happy {
                var arc = Path()
                arc.move(to: CGPoint(x: eyeX - 4, y: eyeY + 1))
                arc.addQuadCurve(to: CGPoint(x: eyeX + 4, y: eyeY + 1),
                                 control: CGPoint(x: eyeX, y: eyeY - 6))
                face.stroke(arc, with: .color(.white),
                            style: StrokeStyle(lineWidth: 2.8, lineCap: .round))
            } else {
                // Slightly unequal eye heights give the neutral face a curious expression.
                let height = max(1.5, (index == 0 ? 11.5 : 10.5) * openness)
                let eye = CGRect(x: eyeX - 3.5, y: eyeY - height / 2, width: 7, height: height)
                face.fill(Path(roundedRect: eye, cornerRadius: min(3.5, height / 2)),
                          with: .color(Color(hex: 0xFDFDFD)))
            }
        }

        if detailed {
            var reflection = Path()
            reflection.move(to: CGPoint(x: 31, y: 39))
            reflection.addQuadCurve(to: CGPoint(x: 44, y: 37.5), control: CGPoint(x: 36, y: 37))
            face.stroke(reflection, with: .color(.white.opacity(0.10)),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    private func eyeOpenness(at time: TimeInterval?) -> CGFloat {
        guard let time else { return 1 }
        // One soft 200 ms blink per 5.4 s; no flashing, random work or scheduled tasks.
        let phase = time.truncatingRemainder(dividingBy: 5.4)
        guard phase > 5.2 else { return 1 }
        let progress = (phase - 5.2) / 0.2
        return CGFloat(1 - sin(progress * .pi) * 0.94)
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

    private func visorPath() -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 36, y: 35))
        path.addCurve(to: CGPoint(x: 72, y: 37),
                      control1: CGPoint(x: 47, y: 33), control2: CGPoint(x: 64, y: 33))
        path.addCurve(to: CGPoint(x: 74, y: 60),
                      control1: CGPoint(x: 80, y: 42), control2: CGPoint(x: 80, y: 55))
        path.addCurve(to: CGPoint(x: 32, y: 61),
                      control1: CGPoint(x: 65, y: 67), control2: CGPoint(x: 42, y: 67))
        path.addCurve(to: CGPoint(x: 36, y: 35),
                      control1: CGPoint(x: 22, y: 56), control2: CGPoint(x: 23, y: 39))
        path.closeSubpath()
        return path
    }
}
