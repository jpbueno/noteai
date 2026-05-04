import Foundation

struct NoteSpaceGroup: Identifiable {
    let title: String
    let notes: [Note]

    var id: String { title }
    var isUnassigned: Bool { title == NoteSpaceOrganizer.unassignedTitle }
}

struct NoteSpaceMutation {
    let spaces: [String]
    let notes: [Note]
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

    static func renamingSpace(
        _ rawOldName: String,
        to rawNewName: String,
        spaces: [String],
        notes: [Note]
    ) -> NoteSpaceMutation? {
        guard let oldName = normalized(rawOldName),
              let newName = normalized(rawNewName),
              !isSystemSpace(oldName),
              !isSystemSpace(newName),
              containsSpace(oldName, spaces: spaces, notes: notes)
        else { return nil }

        let renamedSpaces = spaces.map { existing in
            matches(existing, oldName) ? newName : existing
        }
        let nextSpaces = orderedSpaceTitles(renamedSpaces + [newName])
        let nextNotes = notes.map { note in
            var updated = note
            if matches(note.space, oldName) {
                updated.space = newName
            }
            return updated
        }

        return NoteSpaceMutation(spaces: nextSpaces, notes: nextNotes)
    }

    static func deletingSpace(
        _ rawName: String,
        spaces: [String],
        notes: [Note]
    ) -> NoteSpaceMutation? {
        guard let name = normalized(rawName),
              !isSystemSpace(name),
              containsSpace(name, spaces: spaces, notes: notes)
        else { return nil }

        let nextSpaces = orderedSpaceTitles(spaces.filter { !matches($0, name) })
        let nextNotes = notes.map { note in
            var updated = note
            if matches(note.space, name) {
                updated.space = nil
            }
            return updated
        }

        return NoteSpaceMutation(spaces: nextSpaces, notes: nextNotes)
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

    private static func containsSpace(_ name: String, spaces: [String], notes: [Note]) -> Bool {
        spaces.contains { matches($0, name) } || notes.contains { matches($0.space, name) }
    }

    private static func isSystemSpace(_ name: String) -> Bool {
        matches(name, unassignedTitle)
    }

    private static func matches(_ rawSpace: String?, _ title: String) -> Bool {
        guard let space = normalized(rawSpace) else { return false }
        return space.caseInsensitiveCompare(title) == .orderedSame
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
