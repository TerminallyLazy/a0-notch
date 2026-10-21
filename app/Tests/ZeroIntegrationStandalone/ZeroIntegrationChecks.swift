import AppKit
import SwiftUI

@main @MainActor
private enum ZeroIntegrationChecks {
    static var checks = 0
    static var failures: [String] = []
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message); print("FAIL: \(message)") }
    }
    static func main() {
        _ = NSApplication.shared
        wardrobe()
        motion()
        interaction()
        rendering()
        print("RESULT: \(checks) checks, \(failures.count) failures; real Zero modules, palette-only fixtures.")
        if !failures.isEmpty { exit(1) }
    }
    static func wardrobe() {
        let suite = "a0.zero.integration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = ["auto", "none", "partyHat", "beanie", "crown", "witchHat", "santaHat", "bunnyEars", "bow", "sunglasses", "roundGlasses", "scarf", "haloRing"]
        check(ZeroOutfit.allCases.map(\.rawValue) == ids, "exact stable outfit IDs")
        for id in ids {
            defaults.set(id, forKey: "zeroOutfit")
            let wardrobe = ZeroWardrobe(defaults: defaults)
            check(wardrobe.selected.rawValue == id, "restore \(id)")
            check(defaults.string(forKey: "zeroOutfit") == id, "preserve valid ID \(id)")
            let outfit = ZeroOutfit(rawValue: id)!
            wardrobe.select(outfit)
            check(ZeroWardrobe(defaults: defaults).selected == outfit, "round-trip selection \(id)")
            if outfit != .auto { check(wardrobe.resolved(at: date(12, 25)) == outfit, "explicit selection beats season \(id)") }
        }
        for invalid in ["", "legacyHat", "mochi", "HaloRing", "unknown"] {
            defaults.set(invalid, forKey: "zeroOutfit")
            check(ZeroWardrobe(defaults: defaults).selected == .auto, "migrate unknown ID \(invalid)")
            check(defaults.string(forKey: "zeroOutfit") == "auto", "persist migration \(invalid)")
        }
        defaults.removeObject(forKey: "zeroOutfit")
        check(ZeroWardrobe(defaults: defaults).selected == .auto, "missing key defaults automatic")
        defaults.set(42, forKey: "zeroOutfit")
        check(ZeroWardrobe(defaults: defaults).selected == .auto, "non-string key migrates")
        let boundaries: [(Int, Int, ZeroOutfit)] = [
            (12, 14, .beanie), (12, 15, .santaHat), (12, 30, .santaHat), (12, 31, .partyHat),
            (1, 1, .partyHat), (1, 3, .partyHat), (1, 4, .beanie), (1, 31, .beanie),
            (2, 1, .beanie), (2, 13, .beanie), (2, 14, .bow), (2, 15, .beanie), (2, 28, .beanie),
            (3, 1, .none), (3, 19, .none), (3, 20, .bunnyEars), (3, 31, .bunnyEars),
            (4, 1, .bunnyEars), (4, 7, .bunnyEars), (4, 8, .none),
            (10, 23, .none), (10, 24, .witchHat), (10, 31, .witchHat), (11, 1, .none),
            (11, 30, .none), (12, 1, .beanie)]
        for (month, day, expected) in boundaries {
            check(ZeroOutfit.seasonal(at: date(month, day), timeZone: TimeZone(secondsFromGMT: 0)!) == expected,
                  "season boundary \(month)-\(day)")
        }
        let midnight = date(12, 15, hour: 0)
        check(ZeroOutfit.seasonal(at: midnight.addingTimeInterval(-1), timeZone: TimeZone(secondsFromGMT: 0)!) == .beanie, "season second before start")
        check(ZeroOutfit.seasonal(at: midnight, timeZone: TimeZone(secondsFromGMT: 0)!) == .santaHat, "season midnight start")
        check(ZeroOutfit.seasonal(at: midnight, timeZone: TimeZone(secondsFromGMT: -3600)!) == .beanie, "season respects supplied timezone")
        let automatic = ZeroWardrobe(defaults: defaults)
        check(automatic.resolved(at: midnight) == ZeroOutfit.seasonal(at: midnight), "automatic resolves current timezone")
        print("CHECKED: wardrobe all 13 IDs, persistence/migration, 26 boundaries and timezone edge")
    }
    static func date(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    static func motion() {
        check(ZeroMotion.gaze(dx: .nan, dy: .infinity) == .zero, "invalid gaze neutral")
        let gaze = ZeroMotion.gaze(dx: 260, dy: -200)
        check(abs(gaze.x - tanh(1)) < 1e-12 && abs(gaze.y + tanh(1)) < 1e-12, "gaze independent tanh oracle")
        let huge = ZeroMotion.gaze(dx: .greatestFiniteMagnitude, dy: -.greatestFiniteMagnitude)
        check(huge == CGPoint(x: 1, y: -1), "huge gaze bounded")
        check(ZeroMotion.smooth(from: .zero, to: CGPoint(x: 1, y: -1), elapsed: 0) == .zero, "zero smoothing time")
        let expected = 1 - exp(-1.2)
        let smooth = ZeroMotion.smooth(from: .zero, to: CGPoint(x: 1, y: -1), elapsed: 1)
        check(abs(smooth.x - expected) < 1e-12 && abs(smooth.y + expected) < 1e-12, "smoothing caps delta at 100ms")
        let invalid = ZeroMotion.smooth(from: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), to: .zero, elapsed: .nan)
        check(invalid.x.isFinite && invalid.y.isFinite, "smoothing sanitizes non-finite inputs")
        for t in [Double.nan, .infinity, -.infinity, -1] {
            check(ZeroMotion.blink(at: t) == 1, "invalid blink time neutral \(t)")
            check(ZeroMotion.roll(state: .finished, age: t) == 0, "invalid roll age neutral \(t)")
        }
        var minBlink = 1.0
        for step in 0...12000 {
            let t = Double(step) / 200
            let value = ZeroMotion.blink(at: t)
            check(value.isFinite && value >= 0.039999 && value <= 1, "blink finite bounded at \(t)")
            minBlink = min(minBlink, value)
        }
        check(minBlink < 0.05, "blink actually closes")
        check(ZeroMotion.blink(at: 4.123) == ZeroMotion.blink(at: 4.123), "blink deterministic")
        check(ZeroMotion.roll(state: .finished, age: 0) == 0, "roll starts neutral")
        check(abs(ZeroMotion.roll(state: .finished, age: 0.475) - .pi) < 1e-12, "finished half-turn")
        check(abs(ZeroMotion.roll(state: .dizzy, age: 0.65) - 2 * .pi) < 1e-12, "dizzy mid double-roll")
        check(ZeroMotion.roll(state: .finished, age: 0.95) == 0, "finished ends at equivalent neutral")
        check(ZeroMotion.roll(state: .dizzy, age: 1.3) == 0, "dizzy roll ends")
        for state in ZeroCharacterState.allCases where state != .finished && state != .dizzy {
            check(ZeroMotion.roll(state: state, age: 0.4) == 0, "no roll for \(state)")
        }
        print("CHECKED: motion finite inputs, 12001 blink samples, roll boundaries")
    }
    static func interaction() {
        let input = ZeroInteraction()
        var cues: [String] = []
        input.onCue = { cues.append($0) }
        input.hover(true, now: 0)
        input.update(now: 1.899)
        check(input.emote == nil, "love not early")
        input.update(now: 1.9)
        check(input.emote == .love && cues == ["hover", "love"], "love at 1.9s")
        input.update(now: 3.11)
        check(input.emote == nil, "love expires")
        input.hover(true, now: 4)
        input.update(now: 6)
        check(cues.filter { $0 == "love" }.count == 1, "continuous hover latches love until leave")
        input.hover(false, now: 6)
        input.hover(true, now: 7)
        input.update(now: 8.91)
        check(cues.filter { $0 == "love" }.count == 2, "leave re-arms love")
        input.hover(false, now: 9)
        input.greet(now: 10)
        input.update(now: 11.199)
        check(input.waving, "wave before deadline")
        input.update(now: 11.2)
        check(!input.waving && cues.suffix(2) == ["peek", "greet"], "wave expiry and cues")
        input.play(.content, now: 12)
        check(cues.last == "approve", "content maps to approve")
        input.play(.surprised, now: 13)
        check(cues.last == "pop", "surprise maps to pop")
        input.slap(now: 20)
        input.update(now: 20.799)
        check(input.emote == .annoyed, "annoyed duration before deadline")
        input.update(now: 20.8)
        check(input.emote == nil, "annoyed expiry")
        input.slap(now: 21)
        input.slap(now: 21.69)
        check(input.dizzy && cues.last == "dizzy", "three clicks strictly within 1.7 seconds")
        input.update(now: 24.98)
        check(input.dizzy, "dizzy persists 3.3s")
        input.update(now: 25)
        check(!input.dizzy, "dizzy clears after deadline")
        let boundary = ZeroInteraction()
        boundary.slap(now: 0); boundary.slap(now: 1); boundary.slap(now: 1.7)
        check(!boundary.dizzy, "exact 1.7s click excluded")
        print("CHECKED: interaction love latch, cue mapping, wave/slap/dizzy deadlines")
    }
    static func pixels<V: View>(_ view: V) -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 120, height: 120))
        renderer.scale = 1
        renderer.colorMode = .linear
        guard let image = renderer.cgImage else { failures.append("ImageRenderer produced nil"); return [] }
        var bytes = [UInt8](repeating: 0, count: 120 * 120 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 120, height: 120, bitsPerComponent: 8,
                                    bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        return bytes
    }
    /// Repeated identical ImageRenderer inputs exhibit ±1 in 8-bit antialiased channels.
    /// Ignore only that measured quantization noise, never geometry or meaningful color drift.
    static func differingChannels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) }
        return zip(a, b).filter { abs(Int($0) - Int($1)) > 1 }.count
    }
    static func rendering() {
        let neutral = pixels(ZeroView(tint: .white, animated: false))
        check(neutral.count == 57600, "neutral 120x120 RGBA render")
        guard neutral.count == 57600 else { return }
        check(stride(from: 3, to: neutral.count, by: 4).filter { neutral[$0] > 0 }.count > 3000, "real Canvas nonempty")
        var renders = 1
        for outfit in ZeroOutfit.allCases {
            let image = pixels(ZeroView(tint: .white, animated: false, outfit: outfit))
            check(image.count == neutral.count && image.contains { $0 != 0 }, "render outfit \(outfit)")
            if outfit != .none && outfit != .auto { check(differingChannels(image, neutral) > 100, "outfit \(outfit) visibly rendered") }
            renders += 1
        }
        for state in ZeroCharacterState.allCases {
            let image = pixels(ZeroView(tint: .white, animated: false, state: state))
            check(image.count == neutral.count && image.contains { $0 != 0 }, "render state \(state)")
            if state != .idle { check(differingChannels(image, neutral) > 100, "state \(state) visibly rendered") }
            renders += 1
        }
        for emote in ZeroEmote.allCases {
            let image = pixels(ZeroView(tint: .white, animated: false, emote: emote))
            check(image.count == neutral.count && differingChannels(image, neutral) > 100, "render emote \(emote)")
            renders += 1
        }
        // Compare central eyes only: tint, hands and badge cannot mask missing eye variants.
        func eyeCrop(_ data: [UInt8]) -> [UInt8] {
            guard data.count == neutral.count else { return [] }
            return (52..<68).flatMap { y in (43..<80).flatMap { x in Array(data[(y * 120 + x) * 4..<(y * 120 + x + 1) * 4]) } }
        }
        check(differingChannels(eyeCrop(pixels(ZeroView(tint: .white, animated: false, emote: .surprised))), eyeCrop(neutral)) > 100, "surprise eye dots differ from neutral")
        check(differingChannels(eyeCrop(pixels(ZeroView(tint: .white, animated: false, state: .waiting))), eyeCrop(neutral)) > 100, "waiting wide eyes differ from neutral")
        let repeatedNeutral = pixels(ZeroView(tint: .white, animated: false))
        let repeatDifferences = zip(neutral, repeatedNeutral).filter { $0 != $1 }.count
        print("RENDER REPEAT: \(repeatDifferences) byte differences for identical neutral input")
        check(differingChannels(neutral, repeatedNeutral) == 0, "neutral repeat differs only within one-level quantization")
        let shell = pixels(OriginalZeroShell())
        var shellSamples = 0
        var shellMismatch = 0
        if shell.count == neutral.count {
            // Exterior horizontal bands, away from visor/eyes; one-level quantization only.
            for y in 0..<120 where y < 33 || y > 86 {
                for x in 0..<120 {
                    let i = (y * 120 + x) * 4
                    if shell[i + 3] > 200 {
                        shellSamples += 1
                        if differingChannels(Array(shell[i..<i+4]), Array(neutral[i..<i+4])) > 0 {
                            shellMismatch += 1
                            if shellMismatch <= 8 { print("SHELL DIFF (\(x),\(y)): \(Array(shell[i..<i+4])) vs \(Array(neutral[i..<i+4]))") }
                        }
                    }
                }
            }
        }
        check(shellSamples > 300 && shellMismatch == 0, "original shell exterior preserved (\(shellSamples) samples, \(shellMismatch) differences)")
        let asleep0 = pixels(ZeroView(tint: .white, state: .sleeping, frameTime: 100))
        let asleep1 = pixels(ZeroView(tint: .white, state: .sleeping, frameTime: 100.1))
        check(differingChannels(asleep0, asleep1) > 100, "external 10Hz clock advances sleeping breathing/particles")
        let paused0 = pixels(ZeroView(tint: .white, state: .sleeping, paused: true, frameTime: 100))
        let paused1 = pixels(ZeroView(tint: .white, state: .sleeping, paused: true, frameTime: 101))
        check(differingChannels(paused0, paused1) == 0, "paused external clock renders static")
        print("CHECKED: ImageRenderer \(renders) primary frames (all 13 outfits, 11 states, 7 emotes), original shell pixels, external sleep clock")
    }
}
