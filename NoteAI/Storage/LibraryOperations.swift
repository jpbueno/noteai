import Foundation

struct LibraryFilterResult {
    let meetings: [Meeting]
    let notes: [Note]
    let tasks: [TaskItem]
}

enum LibraryOperations {
    static func filter(
        meetings: [Meeting],
        notes: [Note],
        tasks: [TaskItem],
        query rawQuery: String
    ) -> LibraryFilterResult {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return LibraryFilterResult(meetings: meetings, notes: notes, tasks: tasks)
        }

        return LibraryFilterResult(
            meetings: meetings.filter { meeting in
                meeting.title.lowercased().contains(query) ||
                meeting.summary.topics.contains { $0.lowercased().contains(query) } ||
                meeting.summary.decisions.contains { $0.lowercased().contains(query) } ||
                meeting.summary.actionItems.contains { $0.task.lowercased().contains(query) } ||
                meeting.transcript.contains { $0.text.lowercased().contains(query) }
            },
            notes: notes.filter { note in
                note.title.lowercased().contains(query) ||
                note.content.lowercased().contains(query) ||
                note.tags.contains { $0.lowercased().contains(query) }
            },
            tasks: tasks.filter { task in
                task.title.lowercased().contains(query) ||
                task.rawInput.lowercased().contains(query) ||
                task.description.lowercased().contains(query) ||
                task.tags.contains { $0.lowercased().contains(query) }
            }
        )
    }

    static func notesInRange(_ notes: [Note], start: Date, end: Date) -> [Note] {
        notes.filter { $0.modifiedDate >= start && $0.modifiedDate <= end }
    }

    static func tasksInRange(_ tasks: [TaskItem], start: Date, end: Date) -> [TaskItem] {
        tasks.filter { $0.createdDate >= start && $0.createdDate <= end }
    }

    static func meetingsInRange(_ meetings: [Meeting], start: Date, end: Date) -> [Meeting] {
        meetings.filter { $0.date >= start && $0.date <= end }
    }

    static func t5tDefaultTitle(config: T5TConfig) -> String {
        if config.isComplete && !config.subjectLine.trimmingCharacters(in: .whitespaces).isEmpty {
            return config.subjectLine.trimmingCharacters(in: .whitespaces)
        }
        let vertical = config.vertical.trimmingCharacters(in: .whitespaces)
        let region = config.region.trimmingCharacters(in: .whitespaces)
        let jobFunction = config.jobFunction.trimmingCharacters(in: .whitespaces)
        return "Top 5 Things – \(vertical.isEmpty ? "Inference Ops" : vertical) | \(region.isEmpty ? "NALA" : region) | \(jobFunction.isEmpty ? "SA" : jobFunction)"
    }
}

