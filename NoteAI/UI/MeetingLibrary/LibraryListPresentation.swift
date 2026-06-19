import Foundation

enum LibraryListPresentation {
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MM/dd/yy"
        return formatter
    }()

    static func shortDateString(for date: Date) -> String {
        shortDateFormatter.string(from: date)
    }

    static func taskMetadata(_ task: TaskItem) -> String {
        let status = task.isCompleted ? "Completed" : "Open"
        guard let workDate = task.workDate else {
            return "\(status) • No work date"
        }
        return "\(status) • Work date \(shortDateString(for: workDate))"
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
