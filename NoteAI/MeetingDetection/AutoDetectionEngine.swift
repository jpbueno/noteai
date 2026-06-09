import Foundation

enum AutoDetectionEngine: String, CaseIterable, Identifiable {
    case classicV4 = "classicV4"
    case teamsV5 = "teamsV5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classicV4:
            return "v4 Classic"
        case .teamsV5:
            return "v5 Teams Smart"
        }
    }

    var description: String {
        switch self {
        case .classicV4:
            return "Existing audio/activity detector."
        case .teamsV5:
            return "Confidence-based Teams detector using process, window, and audio signals."
        }
    }
}
