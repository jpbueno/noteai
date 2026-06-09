import Foundation

struct TeamsProcessEvidence: Equatable {
    var pid: Int32
    var bundleIdentifier: String
    var displayName: String
    var frontmost: Bool
}

struct TeamsCallEvidenceSnapshot: Equatable {
    var observedAt: Date
    var teamsProcess: TeamsProcessEvidence?
    var teamsAudioActive: Bool
    var genericOutputAudioActive: Bool
    var callWindowEvidence: Bool
    var calendarArmed: Bool
    var explicitStart: Bool
    var explicitEnd: Bool

    var confidenceScore: Double {
        guard teamsProcess != nil else { return 0 }

        var score = 0.35
        if teamsAudioActive {
            score += 0.35
        } else if genericOutputAudioActive {
            score += 0.10
        }
        if callWindowEvidence {
            score += 0.25
        }
        if calendarArmed {
            score += 0.15
        }
        if teamsProcess?.frontmost == true {
            score += 0.05
        }
        if explicitStart {
            score += 0.50
        }
        return min(score, 1.0)
    }
}

struct TeamsCallStateMachine {
    struct Configuration: Equatable {
        var detectionThreshold: Double
        var startThreshold: Double
        var startDebounce: TimeInterval
        var endGrace: TimeInterval
        var crashGrace: TimeInterval
        var cooldown: TimeInterval

        static let `default` = Configuration(
            detectionThreshold: 0.55,
            startThreshold: 0.65,
            startDebounce: 5,
            endGrace: 90,
            crashGrace: 20,
            cooldown: 15
        )
    }

    enum State: Equatable {
        case idle
        case callDetected(detectedAt: Date, lastEvidenceAt: Date, snapshot: TeamsCallEvidenceSnapshot)
        case recording(startedAt: Date, lastEvidenceAt: Date, snapshot: TeamsCallEvidenceSnapshot)
        case callEnded(endedAt: Date, reason: StopReason)

        var kind: Kind {
            switch self {
            case .idle: return .idle
            case .callDetected: return .callDetected
            case .recording: return .recording
            case .callEnded: return .callEnded
            }
        }

        enum Kind: Equatable {
            case idle
            case callDetected
            case recording
            case callEnded
        }
    }

    enum StopReason: Equatable {
        case endedSignal
        case evidenceLost
        case teamsUnavailable
    }

    enum Event: Equatable {
        case callDetected(snapshot: TeamsCallEvidenceSnapshot)
        case startRecording(snapshot: TeamsCallEvidenceSnapshot)
        case stopRecording(reason: StopReason)
        case returnToIdle

        var kind: Kind {
            switch self {
            case .callDetected: return .callDetected
            case .startRecording: return .startRecording
            case .stopRecording: return .stopRecording
            case .returnToIdle: return .returnToIdle
            }
        }

        enum Kind: Equatable {
            case callDetected
            case startRecording
            case stopRecording
            case returnToIdle
        }
    }

    private(set) var state: State = .idle
    private let configuration: Configuration

    init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    mutating func process(_ snapshot: TeamsCallEvidenceSnapshot) -> [Event] {
        switch state {
        case .idle:
            return processIdle(snapshot)
        case .callDetected(let detectedAt, _, let previousSnapshot):
            return processCallDetected(snapshot, detectedAt: detectedAt, previousSnapshot: previousSnapshot)
        case .recording(let startedAt, let lastEvidenceAt, let previousSnapshot):
            return processRecording(snapshot, startedAt: startedAt, lastEvidenceAt: lastEvidenceAt, previousSnapshot: previousSnapshot)
        case .callEnded(let endedAt, _):
            return processCallEnded(snapshot, endedAt: endedAt)
        }
    }

    private mutating func processIdle(_ snapshot: TeamsCallEvidenceSnapshot) -> [Event] {
        guard isDetectionEvidence(snapshot) else { return [] }

        state = .callDetected(
            detectedAt: snapshot.observedAt,
            lastEvidenceAt: snapshot.observedAt,
            snapshot: snapshot
        )
        return [.callDetected(snapshot: snapshot)]
    }

    private mutating func processCallDetected(
        _ snapshot: TeamsCallEvidenceSnapshot,
        detectedAt: Date,
        previousSnapshot: TeamsCallEvidenceSnapshot
    ) -> [Event] {
        if snapshot.explicitEnd {
            state = .callEnded(endedAt: snapshot.observedAt, reason: .endedSignal)
            return [.stopRecording(reason: .endedSignal)]
        }

        guard isDetectionEvidence(snapshot) else {
            state = .idle
            return [.returnToIdle]
        }

        let candidate = strongerSnapshot(snapshot, previousSnapshot)
        let debounceSatisfied = snapshot.observedAt.timeIntervalSince(detectedAt) >= configuration.startDebounce
        if isStartEvidence(snapshot), debounceSatisfied {
            state = .recording(
                startedAt: snapshot.observedAt,
                lastEvidenceAt: snapshot.observedAt,
                snapshot: candidate
            )
            return [.startRecording(snapshot: candidate)]
        }

        state = .callDetected(
            detectedAt: detectedAt,
            lastEvidenceAt: snapshot.observedAt,
            snapshot: candidate
        )
        return []
    }

    private mutating func processRecording(
        _ snapshot: TeamsCallEvidenceSnapshot,
        startedAt: Date,
        lastEvidenceAt: Date,
        previousSnapshot: TeamsCallEvidenceSnapshot
    ) -> [Event] {
        if snapshot.explicitEnd {
            state = .callEnded(endedAt: snapshot.observedAt, reason: .endedSignal)
            return [.stopRecording(reason: .endedSignal)]
        }

        if isDetectionEvidence(snapshot) {
            state = .recording(
                startedAt: startedAt,
                lastEvidenceAt: snapshot.observedAt,
                snapshot: strongerSnapshot(snapshot, previousSnapshot)
            )
            return []
        }

        let elapsed = snapshot.observedAt.timeIntervalSince(lastEvidenceAt)
        if snapshot.teamsProcess == nil, elapsed >= configuration.crashGrace {
            state = .callEnded(endedAt: snapshot.observedAt, reason: .teamsUnavailable)
            return [.stopRecording(reason: .teamsUnavailable)]
        }
        if elapsed >= configuration.endGrace {
            state = .callEnded(endedAt: snapshot.observedAt, reason: .evidenceLost)
            return [.stopRecording(reason: .evidenceLost)]
        }

        state = .recording(
            startedAt: startedAt,
            lastEvidenceAt: lastEvidenceAt,
            snapshot: previousSnapshot
        )
        return []
    }

    private mutating func processCallEnded(_ snapshot: TeamsCallEvidenceSnapshot, endedAt: Date) -> [Event] {
        guard snapshot.observedAt.timeIntervalSince(endedAt) >= configuration.cooldown else { return [] }
        state = .idle
        return [.returnToIdle]
    }

    private func isDetectionEvidence(_ snapshot: TeamsCallEvidenceSnapshot) -> Bool {
        snapshot.confidenceScore >= configuration.detectionThreshold
    }

    private func isStartEvidence(_ snapshot: TeamsCallEvidenceSnapshot) -> Bool {
        snapshot.confidenceScore >= configuration.startThreshold
    }

    private func strongerSnapshot(
        _ lhs: TeamsCallEvidenceSnapshot,
        _ rhs: TeamsCallEvidenceSnapshot
    ) -> TeamsCallEvidenceSnapshot {
        lhs.confidenceScore >= rhs.confidenceScore ? lhs : rhs
    }
}
