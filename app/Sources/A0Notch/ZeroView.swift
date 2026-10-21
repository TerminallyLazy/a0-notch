import SwiftUI

private struct ZeroReplacedByIslandLayerKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ZeroFrameIntervalKey: EnvironmentKey {
    static let defaultValue = 1.0 / 30
}

private struct ZeroAnimationPausedKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var zeroFrameInterval: Double {
        get { self[ZeroFrameIntervalKey.self] }
        set { self[ZeroFrameIntervalKey.self] = newValue.isFinite ? min(0.1, max(1.0 / 60, newValue)) : 1.0 / 30 }
    }
    var zeroReplacedByIslandLayer: Bool {
        get { self[ZeroReplacedByIslandLayerKey.self] }
        set { self[ZeroReplacedByIslandLayerKey.self] = newValue }
    }

    /// Suspend every descendant ZeroView while its surface is hidden or the screen sleeps/locks.
    /// The host owns lifecycle observation; this does not stop a host's external frame clock.
    var zeroAnimationPaused: Bool {
        get { self[ZeroAnimationPausedKey.self] }
        set { self[ZeroAnimationPausedKey.self] = newValue }
    }
}

/// Original pebble companion, deliberately separate from the official Agent Zero marks.
public struct ZeroView: View {
    let tint: Color
    var gaze: CGPoint
    var animated: Bool
    var happy: Bool
    var state: ZeroCharacterState
    var emote: ZeroEmote?
    var outfit: ZeroOutfit
    var paused: Bool
    var waving: Bool
    /// Optional external animation clock (seconds); disables the internal schedule.
    var frameTime: TimeInterval?
    /// File drag hover only; does not imply a delivered file or upload progress.
    var fileHover: Bool
    @State private var trayOrigin: Double
    @State private var trayStart = Date.timeIntervalSinceReferenceDate
    @State private var stateStart = Date.timeIntervalSinceReferenceDate
    @State private var emoteStart = Date.timeIntervalSinceReferenceDate
    @State private var outfitStart = Date.timeIntervalSinceReferenceDate
    @State private var gazeOrigin: CGPoint = .zero
    @State private var gazeStart = Date.timeIntervalSinceReferenceDate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.zeroFrameInterval) private var frameInterval
    @Environment(\.zeroAnimationPaused) private var inheritedPause
    @Environment(\.zeroReplacedByIslandLayer) private var replacedByIslandLayer

    public init(tint: Color, gaze: CGPoint = .zero, animated: Bool = true, happy: Bool = false,
                state: ZeroCharacterState = .idle, emote: ZeroEmote? = nil,
                outfit: ZeroOutfit = .none, paused: Bool = false, waving: Bool = false,
                frameTime: TimeInterval? = nil, fileHover: Bool = false) {
        self.tint = tint; self.gaze = gaze; self.animated = animated; self.happy = happy
        self.state = state; self.emote = emote; self.outfit = outfit; self.paused = paused
        self.waving = waving; self.frameTime = frameTime
        self.fileHover = fileHover
        _trayOrigin = State(initialValue: fileHover ? 1 : 0)
    }
    private var motion: Bool {
        animated && !paused && !inheritedPause && !reduceMotion && (frameTime?.isFinite ?? true)
    }
    private var stateTint: Color { state == .idle ? tint : state.color }
    private var clock: Double {
        if let frameTime, frameTime.isFinite { return frameTime }
        return Date.timeIntervalSinceReferenceDate
    }

    public var body: some View {
        Group {
            if replacedByIslandLayer {
                Color.clear
            } else if motion, let frameTime {
                character(time: frameTime)
            } else if motion {
                TimelineView(.periodic(from: .now, by: state == .sleeping ? 0.1 : frameInterval)) { timeline in
                    character(time: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                // No internal timer, including for opacity-hidden descendants gated by the host.
                character(time: nil)
            }
        }
        .onAppear {
            let now = clock
            stateStart = now; emoteStart = now; outfitStart = now; gazeStart = now; trayStart = now
        }
        .onChange(of: state) { _, _ in stateStart = clock }
        .onChange(of: emote) { _, _ in emoteStart = clock }
        .onChange(of: outfit) { _, _ in outfitStart = clock }
        .onChange(of: gaze) { old, _ in
            let now = clock
            gazeOrigin = smoothedGaze(at: motion ? now : nil, target: old)
            gazeStart = now
        }
        .onChange(of: fileHover) { old, _ in
            let now = clock
            trayOrigin = trayProgress(at: motion ? now : nil, target: old)
            trayStart = now
        }
        .onChange(of: motion) { _, enabled in
            // Resume at the static pose instead of replaying an old morph or stale gaze.
            guard enabled else { return }
            gazeOrigin = normalizedGaze(gaze); gazeStart = clock
            trayOrigin = fileHover ? 1 : 0; trayStart = clock
        }
        .accessibilityHidden(true)
    }

    private func normalizedGaze(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x.isFinite ? min(1, max(-1, point.x)) : 0,
                y: point.y.isFinite ? min(1, max(-1, point.y)) : 0)
    }

    private func smoothedGaze(at time: Double?, target: CGPoint) -> CGPoint {
        let target = normalizedGaze(target)
        guard let time else { return target }
        let origin = normalizedGaze(gazeOrigin)
        let a = 1 - exp(-max(0, time - gazeStart) * 12)
        return CGPoint(x: origin.x + (target.x - origin.x) * a,
                       y: origin.y + (target.y - origin.y) * a)
    }

    private func trayProgress(at time: Double?, target: Bool) -> Double {
        let destination = target ? 1.0 : 0.0
        guard let time else { return destination }
        let p = min(1, max(0, (time - trayStart) / 0.38))
        // Bounded ease-out-back: a slight bounce, with exact endpoints and no residual loop.
        let q = p - 1
        let eased = 1 + 2.2 * q * q * q + 1.2 * q * q
        return max(0, min(1.1, trayOrigin + (destination - trayOrigin) * eased))
    }

    private static let trayOpening = Path(ellipseIn: CGRect(x: 28, y: 27, width: 46, height: 8))
    private static let cachedVisor = makeVisorPath()
    private static let spiralEye: Path = {
        var path = Path()
        for step in 0...40 {
            let a = Double(step) / 40 * .pi * 4
            let r = Double(step) / 40 * 5
            let point = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }()

    private func character(time: TimeInterval?) -> some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            guard side.isFinite, side > 0 else { return }
            let breath = time.map { sin($0 * 1.65) } ?? 0
            let tray = trayProgress(at: time, target: fileHover)

            // A square design space preserves proportions in both tall cards and short bars.
            // Breathing is a sub-point lift at normal size, not a rubbery body deformation.
            context.translateBy(x: (size.width - side) / 2,
                                y: (size.height - side) / 2 - CGFloat(breath) * side * 0.006)
            context.scaleBy(x: side / 100, y: side / 100)
            let age = max(0, (time ?? stateStart) - stateStart)
            let emotionAge = max(0, (time ?? emoteStart) - emoteStart)
            let t = time ?? 0
            if state != .idle && side >= 48 {
                var halo = context
                halo.addFilter(.blur(radius: 6))
                halo.fill(Path(ellipseIn: CGRect(x: 16, y: 20, width: 70, height: 65)),
                          with: .color(stateTint.opacity(0.2 + (time == nil ? 0 : 0.08 * sin(t * 2)))))
            }
            var body = context
            body.translateBy(x: 50, y: 50)
            var roll = time == nil ? 0 : ZeroMotion.roll(state: state, age: age)
            if state == .question || emote == .wink { roll += 0.17 }
            body.rotate(by: .radians(roll))
            if time != nil {
                if state == .waiting { body.translateBy(x: 0, y: -abs(sin(t * 3)) * 3) }
                if state == .error && age < 0.5 { body.translateBy(x: sin(age * 75) * (1 - age * 2) * 4, y: 0) }
                if emote == .annoyed && emotionAge < 0.37 {
                    let squash = sin(emotionAge / 0.37 * .pi) * 0.16
                    body.scaleBy(x: 1 + squash, y: 1 - squash)
                }
                if emote == .surprised { body.translateBy(x: 0, y: -sin(min(1, emotionAge / 0.5) * .pi) * 8) }
                if emote == .yawn { body.scaleBy(x: 0.96, y: 1.05) }
            }
            body.translateBy(x: -50, y: -50)
            if tray > 0 {
                // Widen and lower the original shell into a shallow receptacle, retaining its
                // materials, face expressions and rigid accessory attachment throughout.
                body.translateBy(x: 50, y: 72)
                body.scaleBy(x: 1 + tray * 0.16, y: 1 - tray * 0.42)
                body.translateBy(x: -50, y: -72)
            }
            drawShell(in: body, detailed: side >= 48)
            if tray > 0 {
                var opening = body
                opening.opacity *= min(1, tray)
                opening.fill(Self.trayOpening, with: .color(A0Theme.background))
                opening.stroke(Self.trayOpening, with: .color(A0Theme.accent.opacity(0.85)), lineWidth: 1.5)
            }
            var look = smoothedGaze(at: time, target: gaze)
            if time != nil {
                if state == .searching { look.x = sin(t * 1.8) * 0.8 }
            }
            if state == .thinking { look = CGPoint(x: 0.65, y: -0.6) }
            drawVisor(in: body, gaze: look, openness: eyeOpenness(at: time), detailed: side >= 48)
            let outfitAge = max(0, (time ?? (outfitStart + 1)) - outfitStart)
            ZeroAccessoryPainter.draw(outfit == .auto ? .seasonal(at: Date()) : outfit, in: body,
                                      time: outfitAge, presence: min(1, outfitAge / 0.35), motion: time != nil)
            drawExtras(in: body, time: time, age: age, detailed: side >= 48)
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

    private func drawVisor(in context: GraphicsContext, gaze: CGPoint,
                           openness: CGFloat, detailed: Bool) {
        var face = context
        // A small face shift suggests looking around without rotating or stretching the shell.
        face.translateBy(x: gaze.x * 1.2, y: gaze.y * 0.8)
        let visor = Self.cachedVisor
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
            if emote == .love || emote == .proud {
                face.draw(Text(emote == .love ? "♥" : "✦")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(emote == .love ? ZeroAccessoryPainter.accent : Color(red: 0.98, green: 0.75, blue: 0.14)),
                          at: CGPoint(x: eyeX, y: eyeY))
            } else if emote == .surprised {
                // Small round dots, distinct from the tall neutral pills.
                let diameter = max(1.5, 5 * openness)
                face.fill(Path(ellipseIn: CGRect(x: eyeX - 2.5, y: eyeY - diameter / 2,
                                                width: 5, height: diameter)), with: .color(.white))
            } else if state == .waiting {
                let height = max(2, 15 * openness)
                face.fill(Path(ellipseIn: CGRect(x: eyeX - 5, y: eyeY - height / 2,
                                                width: 10, height: height)), with: .color(.white))
            } else if state == .dizzy {
                var eye = face
                eye.translateBy(x: eyeX, y: eyeY)
                eye.stroke(Self.spiralEye, with: .color(.white), lineWidth: 1.4)
            } else if state == .sleeping || emote == .yawn || (emote == .wink && index == 0) || emote == .annoyed || state == .error {
                var line = Path()
                let slope: CGFloat = (emote == .annoyed || state == .error) ? (index == 0 ? 2 : -2) : 0
                line.move(to: CGPoint(x: eyeX - 4, y: eyeY - slope))
                line.addLine(to: CGPoint(x: eyeX + 4, y: eyeY + slope))
                face.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: state == .error ? 3.8 : 2.4, lineCap: .round))
            } else if happy || state == .finished || emote == .content {
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
        return CGFloat(ZeroMotion.blink(at: time))
    }

    private func drawExtras(in context: GraphicsContext, time: Double?, age: Double, detailed: Bool) {
        guard detailed else { return }
        let t = time ?? 0
        if emote == .love || emote == .content {
            for x in [28.0, 68.0] {
                context.fill(Path(ellipseIn: CGRect(x: x, y: 60, width: 7, height: 4)),
                             with: .color(ZeroAccessoryPainter.accent.opacity(emote == .love ? 0.65 : 0.35)))
            }
        }
        if waving || state == .waiting || emote == .surprised {
            for side in [-1.0, 1.0] {
                var hand = context
                hand.translateBy(x: 50 + side * 35, y: 60)
                hand.rotate(by: .radians(side * (0.4 + (time == nil ? 0 : sin(t * 9) * 0.35))))
                hand.fill(Path(ellipseIn: CGRect(x: -4, y: -12, width: 8, height: 16)), with: .color(Color(hex: 0xE6E9EE)))
            }
        }
        if let badge = state.badge {
            context.fill(Path(roundedRect: CGRect(x: 67, y: 65, width: 23, height: 15), cornerRadius: 7),
                         with: .color(Color(hex: 0x1A1A1A)))
            context.draw(Text(badge).font(.system(size: 11, weight: .bold)).foregroundColor(stateTint),
                         at: CGPoint(x: 78.5, y: 72.5))
        }
        let sleeping = state == .sleeping || emote == .yawn
        let celebration = (state == .finished && age < 1.5) || emote == .proud
        if sleeping || celebration || emote == .love {
            let symbol = sleeping ? "z" : (emote == .love ? "♥" : "✦")
            let color = sleeping ? Color(hex: 0x94A3B8) : (emote == .love ? ZeroAccessoryPainter.accent : stateTint)
            let glyph = context.resolve(Text(symbol)
                .font(.system(size: sleeping ? 10 : 9, weight: .semibold)).foregroundColor(color))
            for i in 0..<5 {
                let phase = time == nil ? Double(i) / 5 : (t * 0.45 + Double(i) / 5).truncatingRemainder(dividingBy: 1)
                var particle = context
                particle.opacity = time == nil ? 0.5 : sin(phase * .pi) * 0.85
                let x = sleeping ? 74 + Double(i % 2) * 8 : 16 + Double(i) * 17
                particle.draw(glyph,
                              at: CGPoint(x: x, y: 44 - phase * 34))
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

    private static func makeVisorPath() -> Path {
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
