import Foundation
import AppKit

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
        md += "**Duration:** \(meeting.formattedDuration)\n"
        md += "**Source:** `\(sourceLink(for: meeting))`\n"
        md += "**Segments:** \(meeting.transcript.count)\n\n"

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

    static func markdownFilename(for meeting: Meeting) -> String {
        let sanitizedTitle = sanitizeFilenameStem(meeting.title)
        return "\(sanitizedTitle).md"
    }

    static func pdfFilename(for meeting: Meeting) -> String {
        let sanitizedTitle = sanitizeFilenameStem(meeting.title)
        return "\(sanitizedTitle).pdf"
    }

    static func exportAsPDFData(_ meeting: Meeting) throws -> Data {
        try exportMarkdownAsPDFData(exportAsMarkdown(meeting))
    }

    static func exportMarkdownAsPDFData(_ markdown: String) throws -> Data {
        let pageWidth: CGFloat = 612
        let minimumPageHeight: CGFloat = 792
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: minimumPageHeight))
        textView.string = markdown
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: 42, height: 42)
        textView.isEditable = false
        textView.isSelectable = false
        textView.sizeToFit()

        let fittingHeight = max(minimumPageHeight, textView.fittingSize.height + 84)
        textView.frame = NSRect(x: 0, y: 0, width: pageWidth, height: fittingHeight)
        return textView.dataWithPDF(inside: textView.bounds)
    }

    /// Auto-export to the configured vault directory.
    static func autoExportIfEnabled(_ meeting: Meeting) {
        guard UserDefaults.standard.bool(forKey: "autoExportMarkdown") else { return }
        let exportPath = UserDefaults.standard.string(forKey: "markdownExportPath") ?? ""
        guard !exportPath.isEmpty else { return }

        let dir = URL(fileURLWithPath: exportPath)
        let fileURL = dir.appendingPathComponent(markdownFilename(for: meeting))
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

        if !meeting.summary.topics.isEmpty {
            text += "Topics:\n"
            for topic in meeting.summary.topics {
                text += "  * \(topic)\n"
            }
            text += "\n"
        }

        if !meeting.summary.openQuestions.isEmpty {
            text += "Open Questions:\n"
            for question in meeting.summary.openQuestions {
                text += "  * \(question)\n"
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

    static func savePDFToFile(_ meeting: Meeting, directory: URL? = nil) throws -> URL {
        let dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = dir.appendingPathComponent(pdfFilename(for: meeting))
        try exportAsPDFData(meeting).write(to: fileURL, options: .atomic)
        return fileURL
    }

    private static func sourceLink(for meeting: Meeting) -> String {
        "noteai://meeting/\(meeting.id.uuidString)"
    }

    private static func sanitizeFilenameStem(_ title: String) -> String {
        let forbiddenCharacters = CharacterSet(charactersIn: "\\/:*\"<>|")
        let replaced = title.components(separatedBy: forbiddenCharacters).joined(separator: "-")
        let withoutQuestionMarks = replaced.replacingOccurrences(of: "?", with: "")
        let collapsedWhitespace = withoutQuestionMarks
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsedWhitespace.isEmpty ? "Meeting Export" : collapsedWhitespace
    }
}
