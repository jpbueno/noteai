import Foundation

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

    static func isV6(bundleIdentifier: String?, displayName: String?) -> Bool {
        bundleIdentifier == "com.noteai.app.v6" || displayName == "NoteAI v6"
    }

    static func storageNamespace(bundleIdentifier: String?, displayName: String?) -> String {
        isV6(bundleIdentifier: bundleIdentifier, displayName: displayName) ? "NoteAI-v6" : "NoteAI"
    }
}
