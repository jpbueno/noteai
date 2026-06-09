import XCTest
@testable import NoteAI

final class TeamsCallStateMachineTests: XCTestCase {
    func testIdleDoesNotDetectTeamsRunningAlone() {
        var machine = TeamsCallStateMachine(configuration: .test)
        let events = machine.process(.teamsRunningOnly(at: Date(timeIntervalSince1970: 10)))

        XCTAssertEqual(machine.state.kind, .idle)
        XCTAssertTrue(events.isEmpty)
    }

    func testStartsRecordingAfterStrongTeamsEvidenceDebounces() {
        var machine = TeamsCallStateMachine(configuration: .test)
        let first = Date(timeIntervalSince1970: 10)
        let second = first.addingTimeInterval(2)

        let initialEvents = machine.process(.teamsCallEvidence(at: first))
        let startEvents = machine.process(.teamsCallEvidence(at: second))

        XCTAssertEqual(initialEvents.map(\.kind), [.callDetected])
        XCTAssertEqual(startEvents.map(\.kind), [.startRecording])
        XCTAssertEqual(machine.state.kind, .recording)
    }

    func testGenericAudioCannotStartRecordingWithoutTeamsProcess() {
        var machine = TeamsCallStateMachine(configuration: .test)
        let first = Date(timeIntervalSince1970: 10)
        let second = first.addingTimeInterval(2)

        _ = machine.process(.genericAudioOnly(at: first))
        let events = machine.process(.genericAudioOnly(at: second))

        XCTAssertEqual(machine.state.kind, .idle)
        XCTAssertTrue(events.isEmpty)
    }

    func testRecordingSurvivesShortSilenceAndStopsAfterGrace() {
        var machine = TeamsCallStateMachine(configuration: .test)
        let first = Date(timeIntervalSince1970: 10)
        _ = machine.process(.teamsCallEvidence(at: first))
        _ = machine.process(.teamsCallEvidence(at: first.addingTimeInterval(2)))

        let shortSilence = machine.process(.teamsRunningOnly(at: first.addingTimeInterval(4)))
        let stopEvents = machine.process(.teamsRunningOnly(at: first.addingTimeInterval(9)))

        XCTAssertTrue(shortSilence.isEmpty)
        XCTAssertEqual(stopEvents.map(\.kind), [.stopRecording])
        XCTAssertEqual(machine.state.kind, .callEnded)
    }

    func testRecordingStopsWhenOnlyMeetingWindowTitleRemainsAfterCallEnds() {
        var machine = TeamsCallStateMachine(configuration: .test)
        let first = Date(timeIntervalSince1970: 10)
        _ = machine.process(.teamsCallEvidence(at: first))
        _ = machine.process(.teamsCallEvidence(at: first.addingTimeInterval(2)))

        let titleOnly = machine.process(.teamsMeetingWindowTitleOnly(at: first.addingTimeInterval(4)))
        let stopEvents = machine.process(.teamsMeetingWindowTitleOnly(at: first.addingTimeInterval(9)))

        XCTAssertTrue(titleOnly.isEmpty)
        XCTAssertEqual(stopEvents.map(\.kind), [.stopRecording])
        XCTAssertEqual(machine.state.kind, .callEnded)
    }

    func testRecordingContinuesWithTeamsAudioEvenWithoutCallControls() {
        var machine = TeamsCallStateMachine(configuration: .test)
        let first = Date(timeIntervalSince1970: 10)
        _ = machine.process(.teamsCallEvidence(at: first))
        _ = machine.process(.teamsCallEvidence(at: first.addingTimeInterval(2)))

        let events = machine.process(.teamsAudioAndTitleEvidence(at: first.addingTimeInterval(9)))

        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(machine.state.kind, .recording)
    }

    func testRecordingDoesNotStopWhenEvidenceReturnsBeforeGrace() {
        var machine = TeamsCallStateMachine(configuration: .test)
        let first = Date(timeIntervalSince1970: 10)
        _ = machine.process(.teamsCallEvidence(at: first))
        _ = machine.process(.teamsCallEvidence(at: first.addingTimeInterval(2)))

        _ = machine.process(.teamsRunningOnly(at: first.addingTimeInterval(4)))
        let recovered = machine.process(.teamsCallEvidence(at: first.addingTimeInterval(6)))
        let laterSilence = machine.process(.teamsRunningOnly(at: first.addingTimeInterval(9)))

        XCTAssertTrue(recovered.isEmpty)
        XCTAssertTrue(laterSilence.isEmpty)
        XCTAssertEqual(machine.state.kind, .recording)
    }

    func testTeamsCrashStopsRecordingAfterCrashGrace() {
        var machine = TeamsCallStateMachine(configuration: .test)
        let first = Date(timeIntervalSince1970: 10)
        _ = machine.process(.teamsCallEvidence(at: first))
        _ = machine.process(.teamsCallEvidence(at: first.addingTimeInterval(2)))

        let stopEvents = machine.process(.noTeams(at: first.addingTimeInterval(8)))

        XCTAssertEqual(stopEvents, [.stopRecording(reason: .teamsUnavailable)])
        XCTAssertEqual(machine.state.kind, .callEnded)
    }

    func testEndedStateReturnsToIdleAfterCooldown() {
        var machine = TeamsCallStateMachine(configuration: .test)
        let first = Date(timeIntervalSince1970: 10)
        _ = machine.process(.teamsCallEvidence(at: first))
        _ = machine.process(.teamsCallEvidence(at: first.addingTimeInterval(2)))
        _ = machine.process(.noTeams(at: first.addingTimeInterval(8)))

        let events = machine.process(.noTeams(at: first.addingTimeInterval(11)))

        XCTAssertEqual(events.map(\.kind), [.returnToIdle])
        XCTAssertEqual(machine.state.kind, .idle)
    }
}

private extension TeamsCallStateMachine.Configuration {
    static let test = TeamsCallStateMachine.Configuration(
        detectionThreshold: 0.55,
        startThreshold: 0.75,
        startDebounce: 2,
        endGrace: 5,
        crashGrace: 4,
        cooldown: 3
    )
}

private extension TeamsCallEvidenceSnapshot {
    static func teamsRunningOnly(at date: Date) -> TeamsCallEvidenceSnapshot {
        TeamsCallEvidenceSnapshot(
            observedAt: date,
            teamsProcess: TeamsProcessEvidence(
                pid: 42,
                bundleIdentifier: "com.microsoft.teams2",
                displayName: "Microsoft Teams",
                frontmost: false
            ),
            teamsAudioActive: false,
            genericOutputAudioActive: false,
            callControlEvidence: false,
            callWindowTitleEvidence: false,
            calendarArmed: false,
            explicitStart: false,
            explicitEnd: false
        )
    }

    static func teamsCallEvidence(at date: Date) -> TeamsCallEvidenceSnapshot {
        TeamsCallEvidenceSnapshot(
            observedAt: date,
            teamsProcess: TeamsProcessEvidence(
                pid: 42,
                bundleIdentifier: "com.microsoft.teams2",
                displayName: "Microsoft Teams",
                frontmost: true
            ),
            teamsAudioActive: true,
            genericOutputAudioActive: true,
            callControlEvidence: true,
            callWindowTitleEvidence: true,
            calendarArmed: false,
            explicitStart: false,
            explicitEnd: false
        )
    }

    static func teamsMeetingWindowTitleOnly(at date: Date) -> TeamsCallEvidenceSnapshot {
        TeamsCallEvidenceSnapshot(
            observedAt: date,
            teamsProcess: TeamsProcessEvidence(
                pid: 42,
                bundleIdentifier: "com.microsoft.teams2",
                displayName: "Microsoft Teams",
                frontmost: true
            ),
            teamsAudioActive: false,
            genericOutputAudioActive: true,
            callControlEvidence: false,
            callWindowTitleEvidence: true,
            calendarArmed: false,
            explicitStart: false,
            explicitEnd: false
        )
    }

    static func teamsAudioAndTitleEvidence(at date: Date) -> TeamsCallEvidenceSnapshot {
        TeamsCallEvidenceSnapshot(
            observedAt: date,
            teamsProcess: TeamsProcessEvidence(
                pid: 42,
                bundleIdentifier: "com.microsoft.teams2",
                displayName: "Microsoft Teams",
                frontmost: true
            ),
            teamsAudioActive: true,
            genericOutputAudioActive: true,
            callControlEvidence: false,
            callWindowTitleEvidence: true,
            calendarArmed: false,
            explicitStart: false,
            explicitEnd: false
        )
    }

    static func genericAudioOnly(at date: Date) -> TeamsCallEvidenceSnapshot {
        TeamsCallEvidenceSnapshot(
            observedAt: date,
            teamsProcess: nil,
            teamsAudioActive: false,
            genericOutputAudioActive: true,
            callControlEvidence: false,
            callWindowTitleEvidence: false,
            calendarArmed: false,
            explicitStart: false,
            explicitEnd: false
        )
    }

    static func noTeams(at date: Date) -> TeamsCallEvidenceSnapshot {
        TeamsCallEvidenceSnapshot(
            observedAt: date,
            teamsProcess: nil,
            teamsAudioActive: false,
            genericOutputAudioActive: false,
            callControlEvidence: false,
            callWindowTitleEvidence: false,
            calendarArmed: false,
            explicitStart: false,
            explicitEnd: false
        )
    }
}
