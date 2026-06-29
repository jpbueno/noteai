import Foundation

struct AppVersionInfo: Equatable {
    let displayName: String
    let version: String
    let build: String
    let bundleIdentifier: String

    var versionSummary: String {
        "Version \(version) (\(build))"
    }
}

enum AppEnvironment {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "NoteAI"
    }

    static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0"
        if version.hasPrefix("6") { return "v6.0" }
        if version.hasPrefix("5") { return "v5.0" }
        return "v\(version)"
    }

    static var isV6: Bool {
        isV6(bundleIdentifier: Bundle.main.bundleIdentifier, displayName: displayName)
    }

    static var usesTranscriptImportPrimaryFlow: Bool { isV6 }

    static var localCaptureHelperEnabled: Bool { !isV6 }

    static var storageNamespace: String {
        storageNamespace(bundleIdentifier: Bundle.main.bundleIdentifier, displayName: displayName)
    }

    static var keychainService: String {
        Bundle.main.bundleIdentifier ?? "com.noteai.app"
    }

    static func versionInfo() -> AppVersionInfo {
        versionInfo(
            displayName: displayName,
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    static func isV6(bundleIdentifier: String?, displayName: String?) -> Bool {
        bundleIdentifier == "com.noteai.app.v6" || displayName == "NoteAI v6"
    }

    static func storageNamespace(bundleIdentifier: String?, displayName: String?) -> String {
        isV6(bundleIdentifier: bundleIdentifier, displayName: displayName) ? "NoteAI-v6" : "NoteAI"
    }

    static func versionInfo(
        displayName: String?,
        marketingVersion: String?,
        buildNumber: String?,
        bundleIdentifier: String?
    ) -> AppVersionInfo {
        AppVersionInfo(
            displayName: clean(displayName, fallback: "NoteAI"),
            version: clean(marketingVersion, fallback: "Unknown"),
            build: clean(buildNumber, fallback: "Unknown"),
            bundleIdentifier: clean(bundleIdentifier, fallback: "Unknown")
        )
    }

    private static func clean(_ value: String?, fallback: String) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return value
    }
}
