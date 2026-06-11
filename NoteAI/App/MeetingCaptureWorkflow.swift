import Foundation

enum MeetingCaptureWorkflow {
    static func transcriptText(
        from transcript: [TranscriptSegment],
        speakerLabels: [String: String] = [:],
        speakerProfiles: [String: SpeakerProfile] = [:]
    ) -> String {
        transcript
            .map {
                let speaker = TranscriptSpeakerLabels.displayName(
                    for: TranscriptSpeakerLabels.speakerID(for: $0),
                    labels: speakerLabels,
                    profiles: speakerProfiles
                )
                return "[\($0.formattedTimestamp)] \(speaker): \($0.text)"
            }
            .joined(separator: "\n")
    }

    static func summaryInput(
        from transcript: [TranscriptSegment],
        speakerLabels: [String: String] = [:],
        speakerProfiles: [String: SpeakerProfile] = [:]
    ) -> String {
        let context = speakerContext(speakerLabels: speakerLabels, speakerProfiles: speakerProfiles)
        let transcriptText = transcriptText(
            from: transcript,
            speakerLabels: speakerLabels,
            speakerProfiles: speakerProfiles
        )

        guard !context.isEmpty else { return transcriptText }
        return """
        SPEAKER CONTEXT:
        \(context)

        TRANSCRIPT:
        \(transcriptText)
        """
    }

    static func speakerContext(
        speakerLabels: [String: String],
        speakerProfiles: [String: SpeakerProfile]
    ) -> String {
        let profiles = TranscriptSpeakerLabels.normalizedProfiles(speakerProfiles)
        return profiles.keys.sorted().compactMap { speakerID in
            let defaultName = TranscriptSpeakerLabels.displayName(for: speakerID, labels: speakerLabels)
            return profiles[speakerID]?.summaryLine(defaultName: defaultName)
        }
        .joined(separator: "\n")
    }

    static func failedSummary(errorDescription: String) -> MeetingSummary {
        MeetingSummary(
            decisions: [],
            actionItems: [],
            topics: ["Summarization failed: \(errorDescription)"],
            openQuestions: ["Check Settings > AI to verify your API key and model are configured correctly."],
            wasSummarized: false
        )
    }

    static func makeMeeting(
        title: String,
        startedAt: Date?,
        finishedAt: Date = Date(),
        transcript: [TranscriptSegment],
        summary: MeetingSummary,
        speakerLabels: [String: String] = [:],
        speakerProfiles: [String: SpeakerProfile] = [:]
    ) -> Meeting {
        let start = startedAt ?? finishedAt
        return Meeting(
            id: UUID(),
            title: title,
            date: start,
            duration: finishedAt.timeIntervalSince(start),
            transcript: TranscriptSpeakerLabels.assignPlaceholders(to: transcript),
            summary: summary,
            speakerLabels: speakerLabels,
            speakerProfiles: speakerProfiles
        )
    }
}
