import Foundation

enum TranscriptImportParser {
    static func parse(_ rawText: String) -> [TranscriptSegment] {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        var segments: [TranscriptSegment] = []
        var pendingSpeaker: String?
        var pendingTimestamp: Float?
        var pendingText: [String] = []
        var nextID = 1

        func flush() {
            let text = pendingText
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !text.isEmpty else {
                pendingSpeaker = nil
                pendingTimestamp = nil
                pendingText = []
                return
            }
            let start = pendingTimestamp ?? Float(max(segments.count, 0) * 5)
            segments.append(TranscriptSegment(
                id: nextID,
                text: text,
                startTime: start,
                endTime: start + 5,
                speaker: pendingSpeaker,
                confidence: 1
            ))
            nextID += 1
            pendingSpeaker = nil
            pendingTimestamp = nil
            pendingText = []
        }

        for line in lines {
            if line.isEmpty {
                flush()
                continue
            }

            if let header = parseSpeakerTimestampHeader(line) {
                flush()
                pendingSpeaker = header.speaker
                pendingTimestamp = header.timestamp
                continue
            }

            if let timestamp = parseTimestamp(line), pendingText.isEmpty {
                pendingTimestamp = timestamp
                continue
            }

            if pendingText.isEmpty,
               pendingSpeaker == nil,
               !looksLikeSentence(line),
               parseTimestamp(line) == nil {
                pendingSpeaker = line
                continue
            }

            pendingText.append(line)
        }

        flush()

        if segments.isEmpty {
            let fallback = normalized
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !fallback.isEmpty {
                return [TranscriptSegment(id: 1, text: fallback, startTime: 0, endTime: 5, speaker: nil, confidence: 1)]
            }
        }

        return segments
    }

    private static func parseSpeakerTimestampHeader(_ line: String) -> (speaker: String?, timestamp: Float)? {
        let parts = line.split(separator: " ")
        guard let last = parts.last,
              let timestamp = parseTimestamp(String(last)),
              parts.count > 1
        else { return nil }
        let speaker = parts.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (speaker.isEmpty ? nil : speaker, timestamp)
    }

    private static func parseTimestamp(_ raw: String) -> Float? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        if values.count == 2 {
            return Float(values[0] * 60 + values[1])
        }
        return Float(values[0] * 3600 + values[1] * 60 + values[2])
    }

    private static func looksLikeSentence(_ line: String) -> Bool {
        line.contains(".") ||
            line.contains(",") ||
            line.contains("?") ||
            line.contains("!") ||
            line.split(separator: " ").count > 6
    }
}

