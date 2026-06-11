import XCTest
@testable import NoteAI

final class RecordingDiagnosticsTests: XCTestCase {
    func testSnapshotWarnsForDeniedPermissionsAndMissingSystemCapture() {
        var snapshot = RecordingDiagnosticsSnapshot()
        snapshot.updatePermission(.microphone, status: .denied)
        snapshot.updatePermission(.screenRecording, status: .denied)
        snapshot.updateCapture(.systemAudio, status: .unavailable("No meeting app"))

        XCTAssertTrue(snapshot.warnings.contains("Microphone permission is denied."))
        XCTAssertTrue(snapshot.warnings.contains("Screen Recording permission is unavailable."))
        XCTAssertTrue(snapshot.warnings.contains("System audio is not being captured: No meeting app."))
    }

    func testSnapshotRecordsLevelsWithoutAudioPayload() {
        var snapshot = RecordingDiagnosticsSnapshot()
        snapshot.updateCapture(.microphone, status: .capturing)
        snapshot.updateLevel(.microphone, rms: 0.25)

        XCTAssertEqual(snapshot.microphone.level.rms, 0.25, accuracy: 0.0001)
        XCTAssertGreaterThan(snapshot.microphone.level.updatedAt.timeIntervalSince1970, 0)
        XCTAssertEqual(snapshot.microphone.status, .capturing)
    }

    func testProcessTapWarningIsSuppressedWhenSystemAudioIsCapturing() {
        var snapshot = RecordingDiagnosticsSnapshot()
        snapshot.updatePermission(.processTap, status: .unavailable("Failed to create process tap"))
        snapshot.updateCapture(.systemAudio, status: .capturing)

        XCTAssertFalse(snapshot.warnings.contains { $0.contains("Process tap access is unavailable") })
        XCTAssertTrue(snapshot.warnings.isEmpty)
    }

    func testSpeakerVolumeProtectionRestoresOnlyUnexpectedDrops() {
        XCTAssertTrue(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.40))
        XCTAssertTrue(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.67))

        XCTAssertFalse(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.70))
        XCTAssertFalse(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.72))
        XCTAssertFalse(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.80))
    }
}
