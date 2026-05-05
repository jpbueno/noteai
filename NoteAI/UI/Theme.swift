import AppKit
import SwiftUI

enum NoteAIAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

enum CommandCenterLayoutPreset: String, CaseIterable, Identifiable {
    case compact
    case balanced
    case comfortable

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .balanced: return "Balanced"
        case .comfortable: return "Comfortable"
        }
    }

    var spacingMultiplier: CGFloat {
        switch self {
        case .compact: return 0.82
        case .balanced: return 1.0
        case .comfortable: return 1.18
        }
    }

    var panelPaddingMultiplier: CGFloat {
        switch self {
        case .compact: return 0.86
        case .balanced: return 1.0
        case .comfortable: return 1.14
        }
    }

    var cardWidthMultiplier: CGFloat {
        switch self {
        case .compact: return 0.90
        case .balanced: return 1.0
        case .comfortable: return 1.08
        }
    }

    var sidebarWidthAdjustment: CGFloat {
        switch self {
        case .compact: return -12
        case .balanced: return 0
        case .comfortable: return 10
        }
    }
}

/// NoteAI v4 Command Center design tokens.
enum Theme {
    // Mirrors web/src/app/globals.css.
    static let sidebarBG = Color(light: "F8FAFC", dark: "10161B")
    static let contentBG = Color(light: "F3F6F8", dark: "0B0F12")
    static let contentBGNSColor = NSColor(noteAIAdaptiveHexLight: "F3F6F8", dark: "0B0F12")
    static let hoverBG = Color(light: "E8EEF3", dark: "151D23")
    static let selectedBG = Color(light: "DDEFF9", dark: "1B252D")
    static let border = Color(light: "CFDAE3", dark: "26333D")
    static let panelBG = Color(light: "FFFFFF", dark: "10161B").opacity(0.86)
    static let rowBG = Color(light: "FFFFFF", dark: "0F1519")
    static let rowBorder = Color(light: "D8E2EA", dark: "202D36")

    // Text
    static let textPrimary = Color(light: "18232D", dark: "F3F7F9")
    static let textSecondary = Color(light: "45525E", dark: "C4CCD2")
    static let textTertiary = Color(light: "6E7C89", dark: "84919C")

    // Sidebar section headers
    static let sectionHeader = Color(light: "5F6D79", dark: "9BA7AF")

    // Status
    static let accent = Color(light: "0284C7", dark: "64D2FF")
    static let danger = Color(light: "D64555", dark: "FF5C66")
    static let success = Color(light: "168A46", dark: "4ADE80")
    static let warning = Color(light: "B7791F", dark: "FACC15")

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

    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(noteAIHex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(noteAIAdaptiveHexLight light: String, dark: String) {
        self.init(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(noteAIHex: isDark ? dark : light)
        }
    }

    convenience init(noteAIHex: String) {
        let hex = noteAIHex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = CGFloat((int >> 16) & 0xFF) / 255
        let g = CGFloat((int >> 8) & 0xFF) / 255
        let b = CGFloat(int & 0xFF) / 255
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}
