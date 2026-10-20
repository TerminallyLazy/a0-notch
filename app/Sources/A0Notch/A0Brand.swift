import AppKit
import CoreText
import SwiftUI

/// Canonical Agent Zero identity, separate from the provisional Zero character.
@MainActor
enum A0Brand {
    static let resourceBundle: Bundle = {
        // Packaged apps must be self-contained, not use SwiftPM's build-tree fallback.
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }()

    static func url(_ filename: String) -> URL? {
        resourceBundle.url(forResource: filename, withExtension: nil, subdirectory: "Branding")
    }

    static let fontsRegistered: Bool = {
        var succeeded = true
        for file in ["rubik-variable.ttf", "roboto-mono-variable.ttf"] {
            guard let url = url(file) else { succeeded = false; continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // A process-local registration can already exist in previews.
                let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
                if code != CTFontManagerError.alreadyRegistered.rawValue { succeeded = false }
            }
        }
        return succeeded
    }()

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard fontsRegistered, NSFont(name: "Rubik-Regular", size: size) != nil else {
            return .system(size: size, weight: weight)
        }
        return .custom("Rubik-Regular", fixedSize: size).weight(weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard fontsRegistered, NSFont(name: "RobotoMono-Regular", size: size) != nil else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom("RobotoMono-Regular", fixedSize: size).weight(weight)
    }

    static let wordmark = image("AgentZeroWordmark.png")
    static let appIcon = image("AgentZeroIcon.png")
    static let menuIcon: NSImage? = {
        guard let image = image("AgentZeroSymbol.png") else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Agent Zero"
        return image
    }()

    private static func image(_ filename: String) -> NSImage? {
        guard let url = url(filename) else { return nil }
        return NSImage(contentsOf: url)
    }

    static var isValid: Bool {
        fontsRegistered && wordmark != nil && appIcon != nil && menuIcon != nil
            && NSFont(name: "Rubik-Regular", size: 13)?.familyName == "Rubik"
            && NSFont(name: "RobotoMono-Regular", size: 11)?.familyName == "Roboto Mono"
    }
}

struct AgentZeroWordmark: View {
    var body: some View {
        if let image = A0Brand.wordmark {
            Image(nsImage: image).renderingMode(.template).resizable()
                .aspectRatio(163.0 / 26.0, contentMode: .fit)
                .foregroundStyle(.white)
                .accessibilityLabel("Agent Zero")
        } else {
            Text("Agent Zero").font(A0Brand.ui(13, weight: .medium))
        }
    }
}
