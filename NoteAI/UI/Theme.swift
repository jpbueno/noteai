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

/// NoteAI Command Center design tokens.
enum Theme {
    // Codex-inspired workspace palette.
    static let notionWindowBG = Color(light: "FFFFFF", dark: "101010")
    static let notionTopBarBG = Color(light: "F7F7F7", dark: "151515")
    static let notionSidebarBG = Color(light: "F7F7F7", dark: "181818")
    static let notionSurfaceBG = Color(light: "FFFFFF", dark: "191919")
    static let notionHoverBG = Color(light: "EFEFEF", dark: "252525")
    static let notionSelectedBG = Color(light: "EDEDED", dark: "303030")
    static let notionActiveTabBG = Color(light: "FFFFFF", dark: "303030")
    static let notionBorder = Color(light: "DCDCDC", dark: "2A2A2A")
    static let notionIconAccent = Color(light: "C46A13", dark: "D9730D")

    static let sidebarBG = notionSidebarBG
    static let contentBG = notionWindowBG
    static let contentBGNSColor = NSColor(noteAIAdaptiveHexLight: "FFFFFF", dark: "101010")
    static let hoverBG = notionHoverBG
    static let selectedBG = notionSelectedBG
    static let border = notionBorder
    static let panelBG = notionSurfaceBG
    static let rowBG = notionSurfaceBG
    static let rowBorder = notionBorder

    // Text
    static let textPrimary = Color(light: "1F1F1F", dark: "F4F4F4")
    static let textSecondary = Color(light: "4A4A4A", dark: "D6D6D6")
    static let textTertiary = Color(light: "787878", dark: "9B9B9B")

    // Sidebar section headers
    static let sectionHeader = Color(light: "787878", dark: "9B9B9B")

    // Status
    static let accent = Color(light: "2563EB", dark: "2EAADC")
    static let danger = Color(light: "C92A2A", dark: "FF7369")
    static let success = Color(light: "2F8A4C", dark: "4ADE80")
    static let warning = Color(light: "A16207", dark: "D9730D")

    // Content typography
    static let pageTitleSize: CGFloat = 34
    static let h2Size: CGFloat = 22
    static let h3Size: CGFloat = 18
    static let bodySize: CGFloat = 14
    static let smallSize: CGFloat = 12

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
