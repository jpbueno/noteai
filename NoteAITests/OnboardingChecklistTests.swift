import XCTest
@testable import NoteAI

final class OnboardingChecklistTests: XCTestCase {
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
        XCTAssertEqual(checklist.completedCount, 7)
        XCTAssertEqual(checklist.items.first { $0.id == .firstRecording }?.status, .complete)
        XCTAssertNil(checklist.firstRecordingBlocker)
    }
}
