import Foundation

struct SpeakerAttributionHint: Equatable {
    var rawSpeakerID: String
    var confidence: Float
}

struct TranscriptSpeakerAttribution {
    private let minimumRemoteSpeakerConfidence: Float
    private var remoteSpeakerIDsByHint: [String: String] = [:]
    private var nextRemoteSpeakerNumber = 1

    init(minimumRemoteSpeakerConfidence: Float = 0.6) {
        self.minimumRemoteSpeakerConfidence = minimumRemoteSpeakerConfidence
    }

    mutating func attributedSegments(
        _ segments: [TranscriptSegment],
        source: CapturedAudioSource,
        hint: SpeakerAttributionHint? = nil
    ) -> [TranscriptSegment] {
        segments.map { segment in
            attributedSegment(segment, source: source, hint: hint)
        }
    }

    mutating func attributedSegment(
        _ segment: TranscriptSegment,
        source: CapturedAudioSource,
        hint: SpeakerAttributionHint? = nil
    ) -> TranscriptSegment {
        let speakerID = speakerID(source: source, hint: hint)
        return segment.speaker == speakerID ? segment : segment.withSpeaker(speakerID)
    }

    private mutating func speakerID(
        source: CapturedAudioSource,
        hint: SpeakerAttributionHint?
    ) -> String {
        switch source {
        case .microphone:
            return TranscriptSpeakerLabels.localSpeakerID
        case .systemAudio:
            guard let normalizedHint = normalizedRemoteHint(hint) else {
                return TranscriptSpeakerLabels.remoteSpeakerID
            }
            if let existing = remoteSpeakerIDsByHint[normalizedHint] {
                return existing
            }
            let speakerID = "\(TranscriptSpeakerLabels.remoteSpeakerID)-\(nextRemoteSpeakerNumber)"
            nextRemoteSpeakerNumber += 1
            remoteSpeakerIDsByHint[normalizedHint] = speakerID
            return speakerID
        }
    }

    private func normalizedRemoteHint(_ hint: SpeakerAttributionHint?) -> String? {
        guard let hint,
              hint.confidence >= minimumRemoteSpeakerConfidence else {
            return nil
        }

        let normalized = hint.rawSpeakerID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalized.isEmpty ? nil : normalized
    }
}
