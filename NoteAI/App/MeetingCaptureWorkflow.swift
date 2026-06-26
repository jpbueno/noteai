import Foundation

enum MeetingCaptureWorkflow {
    static func transcriptText(from transcript: [TranscriptSegment]) -> String {
        transcript
            .map { "[\($0.formattedTimestamp)] \($0.speaker ?? "Speaker"): \($0.text)" }
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
        sourceEvidence: EvidenceSource? = nil
    ) -> Meeting {
        let start = startedAt ?? finishedAt
        return Meeting(
            id: UUID(),
            title: title,
            date: start,
            duration: finishedAt.timeIntervalSince(start),
            transcript: transcript,
            summary: summary,
            sourceEvidence: sourceEvidence
        )
    }
}
