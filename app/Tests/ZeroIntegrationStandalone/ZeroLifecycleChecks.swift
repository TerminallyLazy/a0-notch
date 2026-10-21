import AppKit
import SwiftUI

/// Separate executable: compile with the real ZeroView, ZeroCharacter, ZeroWardrobe and
/// ZeroPaletteSupport sources, NOT alongside ZeroIntegrationChecks (both have @main).
/// Does not test scheduling wakeups, lifecycle notifications or interactive morph timing.
@main @MainActor
struct ZeroLifecycleChecks {
    static func pixels<V: View>(_ view: V) -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 120, height: 120))
        renderer.scale = 1
        renderer.colorMode = .linear
        guard let image = renderer.cgImage else { fatalError("No renderer output") }
        var bytes = [UInt8](repeating: 0, count: 120 * 120 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 120, height: 120,
                                    bitsPerComponent: 8, bytesPerRow: 480,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        precondition(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 })
        return bytes
    }

    static func differences(_ a: [UInt8], _ b: [UInt8]) -> Int {
        precondition(a.count == b.count)
        // Same one-level linear-render quantization tolerance as the existing real suite.
        return zip(a, b).filter { abs(Int($0) - Int($1)) > 1 }.count
    }

    static func main() {
        for state in ZeroCharacterState.allCases {
            let explicit = pixels(ZeroView(tint: .white, state: state, paused: true, frameTime: 100))
            let inherited = pixels(ZeroView(tint: .white, state: state, frameTime: 101)
                .environment(\.zeroAnimationPaused, true))
            precondition(differences(explicit, inherited) == 0, "Pause mismatch: \(state)")
            let stillPaused = pixels(ZeroView(tint: .white, state: state, paused: true, frameTime: 102)
                .environment(\.zeroAnimationPaused, false))
            precondition(differences(explicit, stillPaused) == 0, "Environment unpaused local pause")
        }
        let neutral = pixels(ZeroView(tint: .white, animated: false))
        let tray = pixels(ZeroView(tint: .white, animated: false, fileHover: true))
        precondition(differences(neutral, tray) > 100, "Tray missing")
        let trayPaused = pixels(ZeroView(tint: .white, frameTime: 103, fileHover: true)
            .environment(\.zeroAnimationPaused, true))
        precondition(differences(tray, trayPaused) == 0, "Paused tray endpoint differs")
        // accessibilityReduceMotion is read-only in the installed macOS SDK.
        // Real OS Reduce Motion remains an interactive check; do not fake its key path.
        let invalidGaze = pixels(ZeroView(tint: .white, gaze: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), animated: false))
        precondition(differences(neutral, invalidGaze) == 0, "Invalid gaze not normalized")
        for time in [Double.nan, Double.infinity, -Double.infinity] {
            precondition(differences(neutral, pixels(ZeroView(tint: .white, frameTime: time))) == 0,
                         "Invalid clock not static")
        }
        let asleep0 = pixels(ZeroView(tint: .white, state: .sleeping, frameTime: 100))
        let asleep1 = pixels(ZeroView(tint: .white, state: .sleeping, frameTime: 100.1))
        precondition(differences(asleep0, asleep1) > 100, "Character sleep must still breathe when awake")
        print("PASS: pause precedence across all states, tray endpoints, invalid inputs, sleeping motion")
    }
}
