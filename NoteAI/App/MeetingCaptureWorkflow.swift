import Foundation

enum MeetingCaptureWorkflow {
    static func transcriptText(from transcript: [TranscriptSegment], speakerLabels: [String: String] = [:]) -> String {
        transcript
            .map {
                let speaker = TranscriptSpeakerLabels.displayName(
                    for: TranscriptSpeakerLabels.speakerID(for: $0),
                    labels: speakerLabels
                )
                return "[\($0.formattedTimestamp)] \(speaker): \($0.text)"
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
        summary: MeetingSummary
    ) -> Meeting {
        let start = startedAt ?? finishedAt
        return Meeting(
            id: UUID(),
            title: title,
            date: start,
            duration: finishedAt.timeIntervalSince(start),
            transcript: TranscriptSpeakerLabels.assignPlaceholders(to: transcript),
            summary: summary
        )
    }
}
