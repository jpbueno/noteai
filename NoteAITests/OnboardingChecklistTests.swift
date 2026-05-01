import XCTest
@testable import NoteAI

final class OnboardingChecklistTests: XCTestCase {
    private func item(
        _ id: OnboardingItemID,
        in checklist: OnboardingChecklist,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> OnboardingChecklistItem {
        guard let item = checklist.items.filter({ $0.id == id }).first else {
            XCTFail("Expected checklist item \(id)", file: file, line: line)
            return OnboardingChecklistItem(
                id: id,
                label: "",
                detail: "",
                actionLabel: nil,
                actionTarget: nil,
                status: .unsupported,
                required: false
            )
        }
        return item
    }

    func testRequiredSetupIsIncompleteUntilPermissionsAndProviderAreReady() {
        let checklist = OnboardingChecklist.build(
            provider: .nvidia,
            providerKeyConfigured: false,
            microphonePermission: .unknown,
            screenRecordingPermission: .denied,
            notificationPermission: .unknown,
            calendarAuthConfigured: false,
            meetingCount: 0
        )

        XCTAssertEqual(checklist.completedCount, 1)
        XCTAssertEqual(checklist.totalCount, 7)
        XCTAssertEqual(checklist.requiredReady, false)
        XCTAssertEqual(checklist.canCollapse, false)
        XCTAssertEqual(checklist.items.map(\.status), [
            .needsAction,
            .blocked,
            .needsAction,
            .needsAction,
            .needsAction,
            .complete,
            .blocked,
        ])
        XCTAssertEqual(checklist.firstRecordingBlocker, "Add your NVIDIA Inference summaries API key before the first recording.")
    }

    func testFirstRecordingValidationAllowsPermissionPromptButRequiresProviderKey() {
        let checklist = OnboardingChecklist.build(
            provider: .openAI,
            providerKeyConfigured: false,
            microphonePermission: .unknown,
            screenRecordingPermission: .granted,
            notificationPermission: .granted,
            calendarAuthConfigured: true,
            meetingCount: 0
        )

        XCTAssertEqual(checklist.requiredReady, false)
        XCTAssertEqual(checklist.canCollapse, false)
        XCTAssertEqual(checklist.firstRecordingBlocker, "Add your OpenAI summaries API key before the first recording.")
    }

    func testUnsupportedPlatformCapabilitiesAreExplicit() {
        let checklist = OnboardingChecklist.build(
            provider: .openRouter,
            providerKeyConfigured: true,
            microphonePermission: .granted,
            screenRecordingPermission: .unsupported("Requires macOS 14.2 or later"),
            notificationPermission: .unsupported("Notifications unavailable"),
            calendarAuthConfigured: false,
            meetingCount: 0
        )

        XCTAssertEqual(checklist.items.first { $0.id == OnboardingItemID.screenRecording }?.status, .unsupported)
        XCTAssertEqual(checklist.items.first { $0.id == OnboardingItemID.notifications }?.status, .unsupported)
        XCTAssertEqual(checklist.requiredReady, false)
    }

    func testFirstRecordingCompletesAfterRequiredSetupAndMeetingExists() {
        let checklist = OnboardingChecklist.build(
            provider: .anthropic,
            providerKeyConfigured: true,
            microphonePermission: .granted,
            screenRecordingPermission: .granted,
            notificationPermission: .granted,
            calendarAuthConfigured: true,
            meetingCount: 1
        )

        XCTAssertEqual(checklist.requiredReady, true)
        XCTAssertEqual(checklist.canCollapse, true)
        XCTAssertEqual(checklist.completedCount, 7)
        XCTAssertEqual(checklist.items.first { $0.id == .firstRecording }?.status, .complete)
        XCTAssertNil(checklist.firstRecordingBlocker)
    }

    func testGrantedScreenRecordingCompletesRequiredSetupAndRemovesRecoveryAction() {
        let checklist = OnboardingChecklist.build(
            provider: .nvidia,
            providerKeyConfigured: true,
            microphonePermission: .granted,
            screenRecordingPermission: .granted,
            notificationPermission: .granted,
            calendarAuthConfigured: true,
            meetingCount: 0
        )

        let screenRecording = item(.screenRecording, in: checklist)
        XCTAssertEqual(screenRecording.status, .complete)
        XCTAssertNil(screenRecording.actionLabel)
        XCTAssertNil(screenRecording.actionTarget)
        XCTAssertEqual(checklist.requiredReady, true)
        XCTAssertEqual(checklist.canCollapse, true)
        XCTAssertNil(checklist.firstRecordingBlocker)
        XCTAssertEqual(item(.firstRecording, in: checklist).status, .needsAction)
    }

    func testScreenAudioPermissionDoesNotHardBlockFirstRecordingAttempt() {
        let checklist = OnboardingChecklist.build(
            provider: .nvidia,
            providerKeyConfigured: true,
            microphonePermission: .granted,
            screenRecordingPermission: .denied,
            notificationPermission: .granted,
            calendarAuthConfigured: true,
            meetingCount: 0
        )

        XCTAssertEqual(checklist.requiredReady, false)
        XCTAssertEqual(checklist.canCollapse, false)
        XCTAssertNil(checklist.firstRecordingBlocker)
        XCTAssertEqual(item(.screenRecording, in: checklist).status, .blocked)
        XCTAssertEqual(item(.firstRecording, in: checklist).status, .needsAction)
        XCTAssertEqual(item(.firstRecording, in: checklist).actionTarget, .startRecording)
    }

    func testPermissionRowsExposeDirectPromptOrRecoveryActions() {
        let unknownChecklist = OnboardingChecklist.build(
            provider: .openRouter,
            providerKeyConfigured: true,
            microphonePermission: .unknown,
            screenRecordingPermission: .unknown,
            notificationPermission: .unknown,
            calendarAuthConfigured: true,
            meetingCount: 0
        )

        XCTAssertEqual(item(.microphone, in: unknownChecklist).actionTarget, .requestMicrophonePermission)
        XCTAssertEqual(item(.microphone, in: unknownChecklist).actionLabel, "Request access")
        XCTAssertEqual(item(.screenRecording, in: unknownChecklist).actionTarget, .requestScreenRecordingPermission)
        XCTAssertEqual(item(.screenRecording, in: unknownChecklist).actionLabel, "Grant Screen & Audio")
        XCTAssertEqual(item(.notifications, in: unknownChecklist).actionTarget, .requestNotificationPermission)
        XCTAssertEqual(item(.notifications, in: unknownChecklist).actionLabel, "Request access")

        let deniedChecklist = OnboardingChecklist.build(
            provider: .openRouter,
            providerKeyConfigured: true,
            microphonePermission: .denied,
            screenRecordingPermission: .denied,
            notificationPermission: .denied,
            calendarAuthConfigured: true,
            meetingCount: 0
        )

        XCTAssertEqual(item(.microphone, in: deniedChecklist).status, .blocked)
        XCTAssertEqual(item(.microphone, in: deniedChecklist).actionTarget, .openMicrophonePrivacySettings)
        XCTAssertEqual(item(.microphone, in: deniedChecklist).actionLabel, "Open Microphone")
        XCTAssertEqual(item(.screenRecording, in: deniedChecklist).actionTarget, .requestScreenRecordingPermission)
        XCTAssertEqual(item(.notifications, in: deniedChecklist).actionTarget, .openNotificationSettings)
        XCTAssertEqual(item(.notifications, in: deniedChecklist).actionLabel, "Open Notifications")
    }

    func testUnsupportedPermissionRowsDoNotExposeActions() {
        let checklist = OnboardingChecklist.build(
            provider: .openRouter,
            providerKeyConfigured: true,
            microphonePermission: .unsupported("No microphone"),
            screenRecordingPermission: .unsupported("Requires macOS 14.2 or later"),
            notificationPermission: .unsupported("Notifications unavailable"),
            calendarAuthConfigured: true,
            meetingCount: 0
        )

        XCTAssertNil(item(.microphone, in: checklist).actionTarget)
        XCTAssertNil(item(.screenRecording, in: checklist).actionTarget)
        XCTAssertNil(item(.notifications, in: checklist).actionTarget)
    }

    func testScreenRecordingRecoveryExplainsRelaunchRequirement() {
        let checklist = OnboardingChecklist.build(
            provider: .openRouter,
            providerKeyConfigured: true,
            microphonePermission: .granted,
            screenRecordingPermission: .denied,
            notificationPermission: .granted,
            calendarAuthConfigured: true,
            meetingCount: 0
        )

        XCTAssertTrue(item(.screenRecording, in: checklist).detail.contains("Screen & System Audio Recording"))
        XCTAssertEqual(item(.screenRecording, in: checklist).actionTarget, .requestScreenRecordingPermission)
    }
}
