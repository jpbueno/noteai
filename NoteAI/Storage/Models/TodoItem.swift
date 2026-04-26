import Foundation

/// Lightweight todo item with an optional due date — mirrors the web TodoItem
/// shape (web/src/lib/types.ts). Separate from TaskItem so dashboards can sort
/// by due date without the heavier "rawInput / tags / source" metadata.
struct TodoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var description: String
    var completed: Bool
    var dueDate: Date?
    let createdDate: Date
    var modifiedDate: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        description: String = "",
        completed: Bool = false,
        dueDate: Date? = nil,
        createdDate: Date = Date(),
        modifiedDate: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.completed = completed
        self.dueDate = dueDate
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
    }

    // MARK: - Due-date groupings (match the web HomeDashboard bucketing)

    enum DueGroup {
        case overdue
        case today
        case upcoming
        case noDueDate
        case completed
    }

    var dueGroup: DueGroup {
        if completed { return .completed }
        guard let due = dueDate else { return .noDueDate }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(due) { return .today }
        if due < cal.startOfDay(for: now) { return .overdue }
        return .upcoming
    }

    /// Human-readable due-date label (e.g. "Today", "Tomorrow", "In 3 days",
    /// "2d overdue", "Jan 15").
    var dueDateLabel: String? {
        guard let due = dueDate else { return nil }
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(due) { return "Today" }
        if cal.isDateInTomorrow(due) { return "Tomorrow" }

        let startDue = cal.startOfDay(for: due)
        let startNow = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: startNow, to: startDue).day ?? 0

        if days < 0 {
            let overdue = -days
            return "\(overdue)d overdue"
        }
        if days <= 7 {
            return "In \(days) days"
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: due)
    }
}
