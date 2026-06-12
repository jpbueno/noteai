import Foundation

#if canImport(EventKit)
import EventKit
#endif

struct MeetingSpeakerSuggestion: Identifiable, Equatable, Hashable {
    let id: String
    let displayName: String
    let email: String?
    let source: String

    init?(name: String?, email: String? = nil, source: String = "Calendar") {
        let normalizedName = Self.normalizedName(name)
        guard !normalizedName.isEmpty else { return nil }

        let normalizedEmail = Self.normalizedEmail(email)
        self.displayName = normalizedName
        self.email = normalizedEmail
        self.source = source
        self.id = normalizedEmail ?? normalizedName.lowercased()
    }

    var subtitle: String {
        email ?? source
    }

    func profile(for speakerID: String) -> SpeakerProfile {
        SpeakerProfile(
            speakerID: speakerID,
            name: displayName,
            notes: email.map { "Calendar attendee: \($0)" }
        )
    }

    static func deduplicated(_ candidates: [MeetingSpeakerSuggestion?]) -> [MeetingSpeakerSuggestion] {
        deduplicate(candidates.compactMap { $0 })
    }

    static func deduplicated(_ candidates: [MeetingSpeakerSuggestion]) -> [MeetingSpeakerSuggestion] {
        deduplicate(candidates)
    }

    private static func deduplicate(_ candidates: [MeetingSpeakerSuggestion]) -> [MeetingSpeakerSuggestion] {
        var seen = Set<String>()
        var results: [MeetingSpeakerSuggestion] = []

        for candidate in candidates {
            let key = candidate.email ?? candidate.displayName.lowercased()
            guard seen.insert(key).inserted else { continue }
            results.append(candidate)
        }

        return results
    }

    private static func normalizedName(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        let trimmed = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}

#if canImport(EventKit)
extension MeetingSpeakerSuggestion {
    static func calendarAttendees(_ attendees: [EKParticipant]?) -> [MeetingSpeakerSuggestion] {
        deduplicated((attendees ?? []).map { attendee in
            MeetingSpeakerSuggestion(
                name: attendee.name,
                email: emailAddress(from: attendee.url)
            )
        })
    }

    private static func emailAddress(from url: URL?) -> String? {
        guard let url else { return nil }
        if url.scheme?.lowercased() == "mailto" {
            return url.absoluteString
                .replacingOccurrences(of: #"(?i)^mailto:"#, with: "", options: .regularExpression)
                .removingPercentEncoding
        }

        let value = url.absoluteString
        return value.contains("@") ? value : nil
    }
}
#endif
