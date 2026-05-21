import AppKit

enum T5TMailDraft {
    static func mailtoURL(for report: T5TReport) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.queryItems = [
            URLQueryItem(name: "subject", value: report.title),
            URLQueryItem(name: "body", value: report.emailBody),
        ]
        return components.url
    }

    static func open(for report: T5TReport) {
        if openInMicrosoftOutlook(report) {
            return
        }

        if let url = mailtoURL(for: report) {
            NSWorkspace.shared.open(url)
        }
    }

    static func htmlBody(for report: T5TReport) -> String {
        var sections: [String] = []

        appendSection(
            title: "Insights, Management Escalations & Help Needed, Market & Competition",
            entries: report.sections.insights,
            to: &sections
        )
        appendSection(
            title: "Industry Business Development / Account Updates",
            entries: report.sections.accountUpdates,
            to: &sections
        )
        appendSection(
            title: "Future Plans",
            entries: report.sections.futurePlans,
            to: &sections
        )

        return """
        <html>
        <body style="margin: 0; font-family: Aptos, Arial, sans-serif;">
        \(sections.joined(separator: "\n"))
        </body>
        </html>
        """
    }

    private static func openInMicrosoftOutlook(_ report: T5TReport) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") != nil else {
            return false
        }

        let source = """
        tell application "Microsoft Outlook"
            set newMessage to make new message with properties {subject:\(appleScriptLiteral(report.title)), content:\(appleScriptLiteral(htmlBody(for: report)))}
            open newMessage
            activate
        end tell
        """

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return false
        }

        script.executeAndReturnError(&error)
        if let error {
            print("Failed to create Outlook T5T draft: \(error)")
            return false
        }

        return true
    }

    private static func appendSection(title: String, entries: [T5TEntry], to sections: inout [String]) {
        guard !entries.isEmpty else {
            return
        }

        let sectionHeading = """
        <div style="font-family: Aptos, Arial, sans-serif; font-size: 13pt; font-weight: 700; margin: 0 0 12px 0;">\(escapeHTML(title))</div>
        """
        let entryBlocks = entries.map { entry in
            """
            <div style="margin: 0 0 14px 0;">
            <div style="font-family: Aptos, Arial, sans-serif; font-size: 11pt; font-weight: 700; margin: 0 0 4px 0;">\(escapeHTML(entry.headline))</div>
            <div style="font-family: Aptos, Arial, sans-serif; font-size: 11pt; font-weight: 400; margin: 0 0 0 4px;">&bull;&nbsp;\(escapeHTML(entry.explanation).components(separatedBy: .newlines).joined(separator: "<br>"))</div>
            </div>
            """
        }

        sections.append(([sectionHeading] + entryBlocks).joined(separator: "\n"))
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { line in
            "\"\(escapeAppleScriptString(line))\""
        }

        return lines.joined(separator: " & linefeed & ")
    }

    private static func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
