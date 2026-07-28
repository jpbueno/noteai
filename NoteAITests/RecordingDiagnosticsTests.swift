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

    func testPublicationPolicyCoalescesRapidLevelsAndPublishesLatestSnapshot() throws {
        var policy = RecordingDiagnosticsPublicationPolicy(minimumInterval: 0.25)
        var first = RecordingDiagnosticsSnapshot()
        first.microphone.level.rms = 0.1
        var second = first
        second.microphone.level.rms = 0.2
        var latest = second
        latest.microphone.level.rms = 0.3

        let initialDirective = policy.submit(first, priority: .coalesced, at: 100)
        let scheduledDirective = policy.submit(second, priority: .coalesced, at: 100.08)
        let coalescedDirective = policy.submit(latest, priority: .coalesced, at: 100.16)
        let flushDirective = policy.flush(at: 100.25)

        guard case .publish(let initialSnapshot) = initialDirective else {
            return XCTFail("Expected the first level snapshot to publish immediately")
        }
        XCTAssertEqual(initialSnapshot.microphone.level.rms, 0.1, accuracy: 0.0001)

        guard case .schedule(let delay) = scheduledDirective else {
            return XCTFail("Expected the second level snapshot to schedule a flush")
        }
        XCTAssertEqual(delay, 0.17, accuracy: 0.0001)
        XCTAssertEqual(coalescedDirective, .none)

        guard case .publish(let latestSnapshot) = flushDirective else {
            return XCTFail("Expected the scheduled flush to publish the latest snapshot")
        }
        XCTAssertEqual(latestSnapshot.microphone.level.rms, 0.3, accuracy: 0.0001)
    }

    func testPublicationPolicyPublishesStateChangesImmediately() throws {
        var policy = RecordingDiagnosticsPublicationPolicy(minimumInterval: 0.25)
        var levelSnapshot = RecordingDiagnosticsSnapshot()
        levelSnapshot.microphone.level.rms = 0.1
        _ = policy.submit(levelSnapshot, priority: .coalesced, at: 100)

        var pendingLevelSnapshot = levelSnapshot
        pendingLevelSnapshot.microphone.level.rms = 0.2
        _ = policy.submit(pendingLevelSnapshot, priority: .coalesced, at: 100.08)

        var stoppedSnapshot = pendingLevelSnapshot
        stoppedSnapshot.updateCapture(.microphone, status: .idle)
        let immediateDirective = policy.submit(stoppedSnapshot, priority: .immediate, at: 100.10)

        guard case .publish(let publishedSnapshot) = immediateDirective else {
            return XCTFail("Expected capture state changes to publish immediately")
        }
        XCTAssertEqual(publishedSnapshot.microphone.status, .idle)
        XCTAssertEqual(policy.flush(at: 100.35), .none)
    }

    func testSpeakerVolumeProtectionRestoresOnlyUnexpectedDrops() {
        XCTAssertTrue(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.40))
        XCTAssertTrue(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.67))

        XCTAssertFalse(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.70))
        XCTAssertFalse(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.72))
        XCTAssertFalse(SpeakerVolumeProtection.shouldRestore(baseline: 0.72, current: 0.80))
    }
}
