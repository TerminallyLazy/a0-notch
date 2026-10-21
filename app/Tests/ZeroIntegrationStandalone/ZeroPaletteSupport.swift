// Minimal TEST SUPPORT ONLY. Values copied from IslandStore.swift's owning theme.
// No Zero enum, view, wardrobe, motion, or interaction replacement is present.
import SwiftUI
@MainActor enum A0Theme {
    static let background = Color(hex: 0x131313)
    static let messageBackground = Color(hex: 0x2D2D2D)
    static let accent = Color(hex: 0xCF6679)
}
extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255,
                  blue: Double(hex & 255) / 255)
    }
}
