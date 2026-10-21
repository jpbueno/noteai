import Foundation
import SwiftUI

enum LibraryListPresentation {
    enum SidebarItemKind {
        case home
        case meeting

        var icon: String {
            switch self {
            case .home: return "rectangle.grid.2x2"
            case .meeting: return "waveform"
            }
        }

        var tint: Color {
            switch self {
            case .home: return Theme.textTertiary
            case .meeting: return Theme.notionIconAccent
            }
        }
    }

    static func shortDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yy"
        return formatter.string(from: date)
    }
}

enum LibraryListOrdering {
    static func meetings(_ meetings: [Meeting]) -> [Meeting] {
        meetings.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
