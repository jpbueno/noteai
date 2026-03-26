import Foundation

/// Exports meetings as Markdown, JSON, or plain text.
enum ExportManager {

    /// Full Markdown export with optional YAML frontmatter and configurable format.
    static func exportAsMarkdown(_ meeting: Meeting) -> String {
        let includeFrontmatter = UserDefaults.standard.bool(forKey: "markdownFrontmatter")
        let includeTimestamps = UserDefaults.standard.object(forKey: "markdownTimestamps") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "markdownTimestamps")

        var md = ""

        // YAML frontmatter
        if includeFrontmatter {
            let isoDate = ISO8601DateFormatter().string(from: meeting.date)
            let topics = meeting.summary.topics.map { "\"\($0)\"" }.joined(separator: ", ")
            md += "---\n"
            md += "title: \"\(meeting.title)\"\n"
            md += "date: \(isoDate)\n"
            md += "duration: \(meeting.formattedDuration)\n"
            md += "segments: \(meeting.transcript.count)\n"
            md += "tags: [meeting, \(topics)]\n"
            md += "type: meeting-notes\n"
            md += "---\n\n"
        }

        md += "# \(meeting.title)\n\n"
        md += "**Date:** \(meeting.date.formatted(date: .long, time: .shortened))\n"
        md += "**Duration:** \(meeting.formattedDuration)\n\n"

        // Summary
        md += "---\n\n"
        md += "## Summary\n\n"

        if !meeting.summary.decisions.isEmpty {
            md += "### Key Decisions\n\n"
            for decision in meeting.summary.decisions {
                md += "- \(decision)\n"
            }
            md += "\n"
        }

        if !meeting.summary.actionItems.isEmpty {
            md += "### Action Items\n\n"
            for item in meeting.summary.actionItems {
                var line = "- [\(item.isCompleted ? "x" : " ")] \(item.task)"
                if let owner = item.owner {
                    line += " — **\(owner)**"
                }
                if let deadline = item.deadline {
                    line += " (by \(deadline))"
                }
                md += line + "\n"
            }
            md += "\n"
        }

        if !meeting.summary.topics.isEmpty {
            md += "### Topics Discussed\n\n"
            for topic in meeting.summary.topics {
                md += "- \(topic)\n"
            }
            md += "\n"
        }

        if !meeting.summary.openQuestions.isEmpty {
            md += "### Open Questions\n\n"
            for question in meeting.summary.openQuestions {
                md += "- \(question)\n"
            }
            md += "\n"
        }

        // Full transcript
        md += "---\n\n"
        md += "## Transcript\n\n"
        for segment in meeting.transcript {
            let speaker = segment.speaker ?? "Speaker"
            if includeTimestamps {
                md += "**[\(segment.formattedTimestamp)] \(speaker):** \(segment.text)\n\n"
            } else {
                md += "**\(speaker):** \(segment.text)\n\n"
            }
        }

        return md
    }

    /// Auto-export to the configured vault directory.
    static func autoExportIfEnabled(_ meeting: Meeting) {
        guard UserDefaults.standard.bool(forKey: "autoExportMarkdown") else { return }
        let exportPath = UserDefaults.standard.string(forKey: "markdownExportPath") ?? ""
        guard !exportPath.isEmpty else { return }

        let dir = URL(fileURLWithPath: exportPath)
        let sanitizedTitle = meeting.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = dir.appendingPathComponent("\(sanitizedTitle).md")
        let content = exportAsMarkdown(meeting)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    static func exportAsJSON(_ meeting: Meeting) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(meeting)
    }

    static func exportAsPlainText(_ meeting: Meeting) -> String {
        var text = "\(meeting.title)\n"
        text += "Date: \(meeting.date.formatted(date: .long, time: .shortened))\n"
        text += "Duration: \(meeting.formattedDuration)\n\n"

        text += "SUMMARY\n"
        text += String(repeating: "=", count: 40) + "\n\n"

        if !meeting.summary.decisions.isEmpty {
            text += "Decisions:\n"
            for decision in meeting.summary.decisions {
                text += "  * \(decision)\n"
            }
            text += "\n"
        }

        if !meeting.summary.actionItems.isEmpty {
            text += "Action Items:\n"
            for item in meeting.summary.actionItems {
                var line = "  * \(item.task)"
                if let owner = item.owner { line += " [\(owner)]" }
                if let deadline = item.deadline { line += " by \(deadline)" }
                text += line + "\n"
            }
            text += "\n"
        }

        text += "\nTRANSCRIPT\n"
        text += String(repeating: "=", count: 40) + "\n\n"
        for segment in meeting.transcript {
            let speaker = segment.speaker ?? "Speaker"
            text += "[\(segment.formattedTimestamp)] \(speaker): \(segment.text)\n"
        }

        return text
    }

    static func saveToFile(_ content: String, filename: String, directory: URL? = nil) throws -> URL {
        let dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = dir.appendingPathComponent(filename)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
