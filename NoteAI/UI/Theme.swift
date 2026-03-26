import SwiftUI

/// Notion-accurate design tokens.
enum Theme {
    // Notion dark mode colors (from screenshots)
    static let sidebarBG = Color(hex: "191919")
    static let contentBG = Color(hex: "1F1F1F")
    static let hoverBG = Color(hex: "252525")
    static let selectedBG = Color(hex: "2B2B2B")
    static let border = Color(hex: "2E2E2E")

    // Text
    static let textPrimary = Color(hex: "EBEBEB")
    static let textSecondary = Color(hex: "9B9B9B")
    static let textTertiary = Color(hex: "5A5A5A")

    // Sidebar section headers
    static let sectionHeader = Color(hex: "7A7A7A")

    // Content typography — Notion uses a serif-like large title
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
