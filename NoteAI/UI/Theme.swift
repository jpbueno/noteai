import SwiftUI

/// NoteAI v4 Command Center design tokens.
enum Theme {
    // Mirrors web/src/app/globals.css.
    static let sidebarBG = Color(hex: "10161B")
    static let contentBG = Color(hex: "0B0F12")
    static let hoverBG = Color(hex: "151D23")
    static let selectedBG = Color(hex: "1B252D")
    static let border = Color(hex: "26333D")
    static let panelBG = Color(hex: "10161B").opacity(0.86)
    static let rowBG = Color(hex: "0F1519")
    static let rowBorder = Color(hex: "202D36")

    // Text
    static let textPrimary = Color(hex: "F3F7F9")
    static let textSecondary = Color(hex: "C4CCD2")
    static let textTertiary = Color(hex: "84919C")

    // Sidebar section headers
    static let sectionHeader = Color(hex: "9BA7AF")

    // Status
    static let accent = Color(hex: "64D2FF")
    static let danger = Color(hex: "FF5C66")
    static let success = Color(hex: "4ADE80")
    static let warning = Color(hex: "FACC15")

    // Content typography
    static let pageTitleSize: CGFloat = 40
    static let h2Size: CGFloat = 24
    static let h3Size: CGFloat = 20
    static let bodySize: CGFloat = 15
    static let smallSize: CGFloat = 13

    // Content width for detail pages. Use full available width.
    static let maxContentWidth: CGFloat = .infinity

    // Spacing
    static let sidebarWidth: CGFloat = 220
    static let pagePadding: CGFloat = 48
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
