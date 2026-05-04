import Foundation

struct NoteSpaceGroup: Identifiable {
    let title: String
    let notes: [Note]

    var id: String { title }
    var isUnassigned: Bool { title == NoteSpaceOrganizer.unassignedTitle }
}

enum NoteSpaceOrganizer {
    static let unassignedTitle = "Unassigned"

    static func normalized(_ space: String?) -> String? {
        guard let trimmed = space?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    static func title(for space: String?) -> String {
        normalized(space) ?? unassignedTitle
    }

    static func orderedSpaceTitles(_ spaces: [String]) -> [String] {
        var seen: Set<String> = []
        var titles: [String] = []

        for space in spaces {
            guard let normalized = normalized(space) else { continue }
            let key = normalized.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            titles.append(normalized)
        }

        return titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func groups(
        for notes: [Note],
        explicitSpaces: [String] = [],
        includeEmptyUnassigned: Bool = false
    ) -> [NoteSpaceGroup] {
        let grouped = Dictionary(grouping: notes) { note in
            title(for: note.space)
        }
        let assignedTitles = orderedSpaceTitles(
            explicitSpaces + grouped.keys.filter { $0 != unassignedTitle }
        )
        let shouldShowUnassigned = includeEmptyUnassigned || grouped[unassignedTitle] != nil
        let orderedTitles = assignedTitles + (shouldShowUnassigned ? [unassignedTitle] : [])

        return orderedTitles.map { title in
            NoteSpaceGroup(title: title, notes: grouped[title] ?? [])
        }
    }
}

struct Note: Identifiable, Codable {
    let id: UUID
    var title: String
    var content: String
    var tags: [String]
    var space: String?
    let createdDate: Date
    var modifiedDate: Date
    var sourceMeetingID: UUID?

    init(id: UUID = UUID(), title: String = "Untitled", content: String = "", tags: [String] = [], space: String? = nil, sourceMeetingID: UUID? = nil, createdDate: Date = Date(), modifiedDate: Date = Date()) {
        self.id = id
        self.title = title
        self.content = content
        self.tags = tags
        self.space = NoteSpaceOrganizer.normalized(space)
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.sourceMeetingID = sourceMeetingID
    }

    var formattedCreatedDate: String {
        createdDate.formatted(date: .abbreviated, time: .shortened)
    }

    var formattedModifiedDate: String {
        modifiedDate.formatted(date: .abbreviated, time: .shortened)
    }
}
