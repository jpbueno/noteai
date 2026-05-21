import Foundation

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
}
