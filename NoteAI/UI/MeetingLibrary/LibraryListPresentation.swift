import Foundation
import SwiftUI

enum LibraryListPresentation {
    enum SidebarItemKind {
        case home
        case t5tReport
        case note
        case task
        case todo
        case meeting

        var icon: String {
            switch self {
            case .home: return "rectangle.grid.2x2"
            case .t5tReport: return "list.bullet.rectangle"
            case .note: return "doc.text"
            case .task: return "checklist"
            case .todo: return "checkmark.square"
            case .meeting: return "waveform"
            }
        }

        var tint: Color {
            switch self {
            case .home: return Theme.textTertiary
            case .t5tReport: return Color(hex: "F59E0B")
            case .note: return Theme.textTertiary
            case .task: return Color(hex: "60A5FA")
            case .todo: return Color(hex: "A78BFA")
            case .meeting: return Theme.notionIconAccent
            }
        }
    }

    static func shortDateString(for date: Date) -> String {
        TaskPresentation.shortDateString(for: date)
    }

    static func taskMetadata(_ task: TaskItem) -> String {
        let status = task.isCompleted ? "Completed" : "Open"
        guard let workDate = task.workDate else {
            return "\(status) • No work date"
        }
        return "\(status) • Work date \(shortDateString(for: workDate))"
    }

    static func taskTitle(_ task: TaskItem) -> String {
        let title = TaskPresentation.displayTitle(for: task)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled task" : title
    }
}

enum LibraryListOrdering {
    static func meetings(_ meetings: [Meeting]) -> [Meeting] {
        meetings.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func notes(_ notes: [Note]) -> [Note] {
        notes.sorted { lhs, rhs in
            if lhs.createdDate != rhs.createdDate { return lhs.createdDate > rhs.createdDate }
            if lhs.modifiedDate != rhs.modifiedDate { return lhs.modifiedDate > rhs.modifiedDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func t5tReports(_ reports: [T5TReport]) -> [T5TReport] {
        reports.sorted { lhs, rhs in
            if lhs.createdDate != rhs.createdDate { return lhs.createdDate > rhs.createdDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func tasks(_ tasks: [TaskItem]) -> [TaskItem] {
        let open = tasks.filter { !$0.isCompleted }
        let completed = tasks.filter(\.isCompleted)
        return sortTasksByActivityDate(open) + sortTasksByActivityDate(completed)
    }

    static func todos(_ todos: [TodoItem]) -> [TodoItem] {
        let pending = todos.filter { !$0.completed }
        let completed = todos.filter(\.completed)
        return sortPendingTodos(pending) + sortCompletedTodos(completed)
    }

    private static func sortTasksByActivityDate(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { lhs, rhs in
            if lhs.activityDate != rhs.activityDate { return lhs.activityDate > rhs.activityDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func sortPendingTodos(_ todos: [TodoItem]) -> [TodoItem] {
        todos.sorted { lhs, rhs in
            switch (lhs.dueDate, rhs.dueDate) {
            case (let lhsDate?, let rhsDate?):
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.createdDate > rhs.createdDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                if lhs.createdDate != rhs.createdDate { return lhs.createdDate > rhs.createdDate }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    private static func sortCompletedTodos(_ todos: [TodoItem]) -> [TodoItem] {
        todos.sorted { lhs, rhs in
            if lhs.modifiedDate != rhs.modifiedDate { return lhs.modifiedDate > rhs.modifiedDate }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}
