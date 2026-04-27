import Foundation

enum OnboardingPermissionStatus: Equatable {
    case unknown
    case granted
    case denied
    case unsupported(String)

    var checklistStatus: OnboardingItemStatus {
        switch self {
        case .granted:
            return .complete
        case .denied:
            return .blocked
        case .unsupported:
            return .unsupported
        case .unknown:
            return .needsAction
        }
    }
}

enum OnboardingItemID: String, CaseIterable {
    case microphone
    case screenRecording
    case notifications
    case aiProvider
    case calendar
    case privacy
    case firstRecording
}

enum OnboardingItemStatus: Equatable {
    case complete
    case needsAction
    case blocked
    case unsupported
}

enum OnboardingActionTarget: Equatable {
    case startRecording
    case openGeneralSettings
    case openAISettings
    case openAccountSettings
    case openPrivacySettings
    case openSystemPrivacySettings
}

struct OnboardingChecklistItem: Equatable, Identifiable {
    let id: OnboardingItemID
    let label: String
    let detail: String
    let actionLabel: String?
    let actionTarget: OnboardingActionTarget?
    let status: OnboardingItemStatus
    let required: Bool
}

struct OnboardingChecklist: Equatable {
    let items: [OnboardingChecklistItem]
    let completedCount: Int
    let totalCount: Int
    let requiredReady: Bool
    let firstRecordingBlocker: String?

    static func build(
        provider: LLMProviderType,
        providerKeyConfigured: Bool,
        microphonePermission: OnboardingPermissionStatus,
        screenRecordingPermission: OnboardingPermissionStatus,
        notificationPermission: OnboardingPermissionStatus,
        calendarAuthConfigured: Bool,
        meetingCount: Int
    ) -> OnboardingChecklist {
        let microphoneStatus = microphonePermission.checklistStatus
        let screenRecordingStatus = screenRecordingPermission.checklistStatus
        let notificationStatus = notificationPermission.checklistStatus
        let requiredReady =
            microphoneStatus == .complete &&
            screenRecordingStatus == .complete &&
            providerKeyConfigured
        let firstRecordingBlocker = Self.firstRecordingBlocker(
            provider: provider,
            providerKeyConfigured: providerKeyConfigured,
            microphonePermission: microphonePermission,
            screenRecordingPermission: screenRecordingPermission,
            meetingCount: meetingCount
        )

        let items = [
            OnboardingChecklistItem(
                id: .microphone,
                label: "Microphone access",
                detail: "Required to capture your voice during meetings.",
                actionLabel: "Start recording",
                actionTarget: .startRecording,
                status: microphoneStatus,
                required: true
            ),
            OnboardingChecklistItem(
                id: .screenRecording,
                label: "Screen Recording",
                detail: screenRecordingStatus == .unsupported
                    ? "System audio capture requires macOS 14.2 or later."
                    : "Required to capture meeting audio from Teams and browsers.",
                actionLabel: "Open System Settings",
                actionTarget: .openSystemPrivacySettings,
                status: screenRecordingStatus,
                required: true
            ),
            OnboardingChecklistItem(
                id: .notifications,
                label: "Notifications",
                detail: "Optional alerts when summaries finish processing.",
                actionLabel: "Open General settings",
                actionTarget: .openGeneralSettings,
                status: notificationStatus,
                required: false
            ),
            OnboardingChecklistItem(
                id: .aiProvider,
                label: "\(provider.displayName) summaries",
                detail: "Choose local-first transcription with a cloud summarization provider and save the API key.",
                actionLabel: "Open AI settings",
                actionTarget: .openAISettings,
                status: providerKeyConfigured ? .complete : .needsAction,
                required: true
            ),
            OnboardingChecklistItem(
                id: .calendar,
                label: "Calendar account",
                detail: "Optional Google account connection for future calendar-aware meeting context.",
                actionLabel: "Open Account settings",
                actionTarget: .openAccountSettings,
                status: calendarAuthConfigured ? .complete : .needsAction,
                required: false
            ),
            OnboardingChecklistItem(
                id: .privacy,
                label: "Privacy controls",
                detail: "Review audio retention and cloud usage before recording sensitive meetings.",
                actionLabel: "Open Privacy settings",
                actionTarget: .openPrivacySettings,
                status: .complete,
                required: false
            ),
            OnboardingChecklistItem(
                id: .firstRecording,
                label: "First recording",
                detail: requiredReady
                    ? "You can record, transcribe, and summarize meetings."
                    : firstRecordingBlocker ?? "Complete required setup to avoid a failed first capture.",
                actionLabel: "Start recording",
                actionTarget: .startRecording,
                status: meetingCount > 0 ? .complete : firstRecordingBlocker == nil ? .needsAction : .blocked,
                required: false
            ),
        ]

        return OnboardingChecklist(
            items: items,
            completedCount: items.filter { $0.status == .complete }.count,
            totalCount: items.count,
            requiredReady: requiredReady,
            firstRecordingBlocker: firstRecordingBlocker
        )
    }

    private static func firstRecordingBlocker(
        provider: LLMProviderType,
        providerKeyConfigured: Bool,
        microphonePermission: OnboardingPermissionStatus,
        screenRecordingPermission: OnboardingPermissionStatus,
        meetingCount: Int
    ) -> String? {
        if meetingCount > 0 {
            return nil
        }

        if !providerKeyConfigured {
            return "Add your \(provider.displayName) summaries API key before the first recording."
        }

        switch microphonePermission {
        case .denied:
            return "Grant Microphone access before the first recording."
        case .unsupported(let reason):
            return "Microphone capture is unavailable: \(reason)"
        case .unknown, .granted:
            break
        }

        switch screenRecordingPermission {
        case .denied:
            return "Grant Screen Recording access before the first recording."
        case .unsupported(let reason):
            return "System audio capture is unavailable: \(reason)"
        case .unknown, .granted:
            break
        }

        return nil
    }
}
