import Foundation

enum TaskPresentation {
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MM/dd/yy"
        return formatter
    }()

    private static let longTitlePrefixRegex = try? NSRegularExpression(
        pattern: #"^\s*([A-Za-z]+)\s+([0-9]{1,2}),\s+([0-9]{4})\s*[-–—]\s*(.+?)\s*$"#,
        options: []
    )

    static func shortDateString(for date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    static func displayTitle(for task: TaskItem) -> String {
        normalizedLongDateTitle(task.title) ?? task.title
    }

    @discardableResult
    static func normalizeStoredTitleDatePrefix(_ task: inout TaskItem) -> Bool {
        guard let normalized = normalizedLongDateTitle(task.title),
              normalized != task.title else {
            return false
        }
        task.title = normalized
        return true
    }

    private static func normalizedLongDateTitle(_ title: String) -> String? {
        guard let regex = longTitlePrefixRegex,
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              match.numberOfRanges == 5,
              let monthRange = Range(match.range(at: 1), in: title),
              let dayRange = Range(match.range(at: 2), in: title),
              let yearRange = Range(match.range(at: 3), in: title),
              let restRange = Range(match.range(at: 4), in: title) else {
            return nil
        }

        let dateText = "\(title[monthRange]) \(title[dayRange]), \(title[yearRange])"
        guard let date = parseLongDatePrefix(dateText) else {
            return nil
        }

        let rest = title[restRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else {
            return nil
        }
        return "\(shortDateString(for: date)) - \(rest)"
    }

    private static func parseLongDatePrefix(_ value: String) -> Date? {
        for format in ["MMMM d, yyyy", "MMM d, yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = .current
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
