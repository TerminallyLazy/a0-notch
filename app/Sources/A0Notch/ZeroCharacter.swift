import Foundation
import Observation
import SwiftUI

public enum ZeroCharacterState: String, CaseIterable, Sendable {
    case idle, working, thinking, searching, delegating, waiting, question, error, finished, sleeping, dizzy
    public var color: Color {
        let rgb: UInt32 = switch self {
        case .idle: 0xE6E9EE
        case .working: 0xFBBF24
        case .thinking, .question: 0x38BDF8
        case .searching: 0x818CF8
        case .delegating: 0x14B8A6
        case .waiting, .dizzy: 0xCF6679
        case .error: 0xE72323
        case .finished: 0x22C55E
        case .sleeping: 0x94A3B8
        }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    public var badge: String? {
        switch self {
        case .working, .thinking, .searching: "•••"
        case .delegating: "→1"
        case .waiting: "!"
        case .question: "?"
        case .error, .finished: "•"
        default: nil
        }
    }
}
public enum ZeroEmote: String, CaseIterable, Sendable { case love, surprised, proud, wink, yawn, content, annoyed }

/// Pure time functions permit reproducible frame tests without a display or global randomness.
public enum ZeroMotion {
    public static func gaze(dx: Double, dy: Double) -> CGPoint {
        CGPoint(x: dx.isFinite ? tanh(dx / 260) : 0, y: dy.isFinite ? tanh(dy / 200) : 0)
    }
    public static func smooth(from: CGPoint, to: CGPoint, elapsed: Double) -> CGPoint {
        let a = 1 - exp(-min(0.1, max(0, elapsed.isFinite ? elapsed : 0)) * 12)
        func component(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(-1, value)) : 0 }
        let origin = CGPoint(x: component(from.x), y: component(from.y))
        let target = CGPoint(x: component(to.x), y: component(to.y))
        return CGPoint(x: origin.x + (target.x - origin.x) * a,
                       y: origin.y + (target.y - origin.y) * a)
    }
    public static func blink(at time: Double, seed: UInt64 = 17) -> Double {
        guard time.isFinite, time >= 0 else { return 1 }
        // Bounded deterministic pseudo-random schedule: 12 intervals, 2.2–5.4s,
        // with roughly 22% double blinks. No allocation or RNG per rendered frame.
        var random = seed
        var cursor = time.truncatingRemainder(dividingBy: 60)
        for _ in 0..<28 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let interval = 2.2 + Double((random >> 32) % 3201) / 1000
            if cursor < interval {
                let phase = interval - cursor
                if phase < 0.18 { return 1 - sin(phase / 0.18 * .pi) * 0.96 }
                if random % 100 < 22 && phase > 0.25 && phase < 0.43 {
                    return 1 - sin((phase - 0.25) / 0.18 * .pi) * 0.96
                }
                return 1
            }
            cursor -= interval
        }
        return 1
    }
    public static func roll(state: ZeroCharacterState, age: Double) -> Double {
        guard age >= 0 else { return 0 }
        let duration = state == .dizzy ? 1.3 : 0.95
        guard state == .dizzy || state == .finished, age < duration else { return 0 }
        let p = age / duration
        return (p * p * (3 - 2 * p)) * .pi * (state == .dizzy ? 4 : 2)
    }
}

/// Optional input adapter for the island owner. It has no timer, store or sound dependency.
/// Call update(now:) from an existing display loop; use monotonic system uptime throughout.
@MainActor @Observable
public final class ZeroInteraction {
    public private(set) var emote: ZeroEmote?
    public private(set) var dizzy = false
    public private(set) var waving = false
    public var onCue: (String) -> Void = { _ in }
    @ObservationIgnored private var hoverStart: Double?
    @ObservationIgnored private var hoverLoveTriggered = false
    @ObservationIgnored private var deadline: Double?
    @ObservationIgnored private var waveDeadline: Double?
    @ObservationIgnored private var clicks: [Double] = []
    public init() {}
    public func hover(_ inside: Bool, now: Double = ProcessInfo.processInfo.systemUptime) {
        if inside && hoverStart == nil { hoverStart = now; onCue("hover") }
        if !inside { hoverStart = nil; hoverLoveTriggered = false }
    }
    public func greet(now: Double = ProcessInfo.processInfo.systemUptime) {
        waving = true; waveDeadline = now + 1.2; onCue("peek"); onCue("greet")
    }
    public func slap(now: Double = ProcessInfo.processInfo.systemUptime) {
        clicks = clicks.filter { now - $0 < 1.7 }; clicks.append(now)
        onCue("slap")
        if clicks.count >= 3 {
            dizzy = true; emote = nil; deadline = now + 3.3; clicks.removeAll(); onCue("dizzy")
        } else { play(.annoyed, duration: 0.8, now: now) }
    }
    public func play(_ value: ZeroEmote, duration: Double = 1.2, now: Double = ProcessInfo.processInfo.systemUptime) {
        emote = value; deadline = now + max(0, duration)
        onCue(value == .surprised ? "pop" : (value == .content ? "approve" : value.rawValue))
    }
    public func update(now: Double = ProcessInfo.processInfo.systemUptime) {
        if let waveDeadline, now >= waveDeadline { waving = false; self.waveDeadline = nil }
        if let deadline, now >= deadline { emote = nil; dizzy = false; self.deadline = nil }
        if let hoverStart, !hoverLoveTriggered, now - hoverStart >= 1.9 {
            hoverLoveTriggered = true
            play(.love, now: now)
        }
    }
}
