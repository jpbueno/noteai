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

enum AutoDetectionDefaults {
    static let autoDetectKey = "autoDetectMeetings"
    static let engineKey = "autoDetectionEngine"
    private static let v5MigrationKey = "autoDetectionV5DefaultMigrated"

    static func migrateToV5DefaultsIfNeeded(_ defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: v5MigrationKey) == false else { return }

        if defaults.object(forKey: engineKey) == nil {
            defaults.set(true, forKey: autoDetectKey)
            defaults.set(AutoDetectionEngine.teamsV5.rawValue, forKey: engineKey)
        }

        defaults.set(true, forKey: v5MigrationKey)
    }

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: autoDetectKey)
    }

    static func engine(_ defaults: UserDefaults = .standard) -> AutoDetectionEngine {
        let engineRaw = defaults.string(forKey: engineKey) ?? AutoDetectionEngine.teamsV5.rawValue
        return AutoDetectionEngine(rawValue: engineRaw) ?? .teamsV5
    }
}
