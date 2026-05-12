import Foundation

/// Lightweight todo item with an optional due date — mirrors the web TodoItem
/// shape (web/src/lib/types.ts).
struct TodoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var description: String
    var completed: Bool
    var dueDate: Date?
    var sourceMeetingID: UUID?
    var sourceActionItemID: String?
    var owner: String?
    let createdDate: Date
    var modifiedDate: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        description: String = "",
        completed: Bool = false,
        dueDate: Date? = nil,
        sourceMeetingID: UUID? = nil,
        sourceActionItemID: String? = nil,
        owner: String? = nil,
        createdDate: Date = Date(),
        modifiedDate: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.completed = completed
        self.dueDate = dueDate
        self.sourceMeetingID = sourceMeetingID
        self.sourceActionItemID = sourceActionItemID
        let trimmedOwner = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.owner = trimmedOwner?.isEmpty == false
            ? trimmedOwner
            : nil
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
    }

    var isActionLinked: Bool {
        sourceMeetingID != nil && sourceActionItemID != nil
    }

    func isLinked(to meetingID: UUID) -> Bool {
        sourceMeetingID == meetingID
    }

    static func actionLinkedTodo(for actionItem: ActionItem, meeting: Meeting, now: Date = Date()) -> TodoItem {
        let deadline = actionItem.deadline?.trimmingCharacters(in: .whitespacesAndNewlines)
        var descriptionParts = ["From meeting: \(meeting.title)"]
        if let owner = actionItem.owner {
            descriptionParts.append("Owner: \(owner)")
        }
        if let deadline, !deadline.isEmpty {
            descriptionParts.append("Deadline: \(deadline)")
        }

        return TodoItem(
            title: actionItem.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled action item"
                : actionItem.task,
            description: descriptionParts.joined(separator: "\n"),
            completed: actionItem.isCompleted,
            dueDate: dueDate(from: deadline),
            sourceMeetingID: meeting.id,
            sourceActionItemID: actionItem.id,
            owner: actionItem.owner,
            createdDate: now,
            modifiedDate: now
        )
    }

    static func mergingActionLinkedTodos(existing: [TodoItem], meeting: Meeting, now: Date = Date()) -> [TodoItem] {
        var merged = existing
        let meetingLinkedIndexes = linkedIndexes(for: meeting.id, in: merged)
        let linkedIndexesByKey = linkIndexes(in: merged)
        var usedIndexes = Set<Int>()

        for actionItem in meeting.summary.actionItems {
            guard !actionItem.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = linkKey(meetingID: meeting.id, actionItemID: actionItem.id)
            let desired = actionLinkedTodo(for: actionItem, meeting: meeting, now: now)

            if let existingIndex = linkedIndexesByKey[key], !usedIndexes.contains(existingIndex) {
                let refreshed = merged[existingIndex].refreshingSourceFields(from: desired, now: now)
                merged[existingIndex] = refreshed
                usedIndexes.insert(existingIndex)
            } else if let existingIndex = meetingLinkedIndexes.first(where: { !usedIndexes.contains($0) }) {
                let refreshed = merged[existingIndex].refreshingSourceFields(from: desired, now: now)
                merged[existingIndex] = refreshed
                usedIndexes.insert(existingIndex)
            } else {
                merged.insert(desired, at: 0)
            }
        }

        for existingIndex in meetingLinkedIndexes where !usedIndexes.contains(existingIndex) {
            merged[existingIndex] = merged[existingIndex].unlinkedFromSource(now: now)
        }

        return merged
    }

    private func refreshingSourceFields(from source: TodoItem, now: Date) -> TodoItem {
        var refreshed = self
        refreshed.title = source.title
        refreshed.description = source.description
        refreshed.dueDate = source.dueDate
        refreshed.sourceMeetingID = source.sourceMeetingID
        refreshed.sourceActionItemID = source.sourceActionItemID
        refreshed.owner = source.owner
        if refreshed != self {
            refreshed.modifiedDate = now
        }
        return refreshed
    }

    private func unlinkedFromSource(now: Date) -> TodoItem {
        guard sourceMeetingID != nil || sourceActionItemID != nil else { return self }
        var unlinked = self
        unlinked.sourceMeetingID = nil
        unlinked.sourceActionItemID = nil
        unlinked.modifiedDate = now
        return unlinked
    }

    static func linkKey(meetingID: UUID, actionItemID: String) -> String {
        "\(meetingID.uuidString.lowercased())|\(actionItemID)"
    }

    private static func linkKey(for todo: TodoItem) -> String? {
        guard let sourceMeetingID = todo.sourceMeetingID,
              let sourceActionItemID = todo.sourceActionItemID else { return nil }
        return linkKey(meetingID: sourceMeetingID, actionItemID: sourceActionItemID)
    }

    private static func linkIndexes(in todos: [TodoItem]) -> [String: Int] {
        var indexes: [String: Int] = [:]
        for (index, todo) in todos.enumerated() {
            guard let key = linkKey(for: todo), indexes[key] == nil else { continue }
            indexes[key] = index
        }
        return indexes
    }

    private static func linkedIndexes(for meetingID: UUID, in todos: [TodoItem]) -> [Int] {
        todos.indices.filter { todos[$0].sourceMeetingID == meetingID }
    }

    private static func dueDate(from deadline: String?) -> Date? {
        guard let deadline, !deadline.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: deadline) {
            return date
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dayFormatter.date(from: deadline) {
            return date
        }

        let mediumFormatter = DateFormatter()
        mediumFormatter.locale = Locale(identifier: "en_US_POSIX")
        mediumFormatter.dateStyle = .medium
        mediumFormatter.timeStyle = .none
        mediumFormatter.isLenient = true
        return mediumFormatter.date(from: deadline)
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

/// Durable work-tracking record used for meeting action items, AI task lists,
/// and T5T source material. Todos stay lightweight reminders; Tasks carry the
/// report-worthy context.
struct TaskItem: Identifiable, Codable, Equatable {
    enum Status: String, Codable, Equatable {
        case open
        case completed
    }

    enum SourceKind: String, Codable, Equatable {
        case email
        case unknown

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            self = SourceKind(rawValue: value) ?? .unknown
        }
    }

    struct SourceMetadata: Codable, Equatable {
        var kind: SourceKind
        var provider: String?
        var threadID: String?
        var messageID: String?
        var subject: String?
        var sender: String?
        var sentDate: Date?
        var url: String?

        init(
            kind: SourceKind = .unknown,
            provider: String? = nil,
            threadID: String? = nil,
            messageID: String? = nil,
            subject: String? = nil,
            sender: String? = nil,
            sentDate: Date? = nil,
            url: String? = nil
        ) {
            self.kind = kind
            self.provider = Self.clean(provider)
            self.threadID = Self.clean(threadID)
            self.messageID = Self.clean(messageID)
            self.subject = Self.clean(subject)
            self.sender = Self.clean(sender)
            self.sentDate = sentDate
            self.url = Self.clean(url)
        }

        var hasAnyValue: Bool {
            kind != .unknown ||
            provider != nil ||
            threadID != nil ||
            messageID != nil ||
            subject != nil ||
            sender != nil ||
            sentDate != nil ||
            url != nil
        }

        var providerDisplayName: String {
            switch provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "outlook":
                return "Outlook"
            case let provider? where !provider.isEmpty:
                return provider
            default:
                return kind == .email ? "Email" : "Source"
            }
        }

        private static func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    let id: UUID
    var title: String
    var description: String
    var status: Status
    var workDate: Date?
    var completedDate: Date?
    var sourceMeetingID: UUID?
    var sourceActionItemID: String?
    var sourceNoteID: UUID?
    var sourceMetadata: SourceMetadata?
    var owner: String?
    let createdDate: Date
    var modifiedDate: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        description: String = "",
        status: Status = .open,
        workDate: Date? = nil,
        completedDate: Date? = nil,
        sourceMeetingID: UUID? = nil,
        sourceActionItemID: String? = nil,
        sourceNoteID: UUID? = nil,
        sourceMetadata: SourceMetadata? = nil,
        owner: String? = nil,
        createdDate: Date = Date(),
        modifiedDate: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.status = status
        self.workDate = workDate
        self.completedDate = completedDate
        self.sourceMeetingID = sourceMeetingID
        self.sourceActionItemID = sourceActionItemID
        self.sourceNoteID = sourceNoteID
        self.sourceMetadata = sourceMetadata?.hasAnyValue == true ? sourceMetadata : nil
        let trimmedOwner = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.owner = trimmedOwner?.isEmpty == false ? trimmedOwner : nil
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
    }

    var isCompleted: Bool {
        status == .completed
    }

    var activityDate: Date {
        completedDate ?? workDate ?? max(createdDate, modifiedDate)
    }

    func isLinked(to meetingID: UUID) -> Bool {
        sourceMeetingID == meetingID
    }

    static func fromLegacyTodo(_ todo: TodoItem) -> TaskItem {
        TaskItem(
            id: todo.id,
            title: todo.title,
            description: todo.description,
            status: todo.completed ? .completed : .open,
            workDate: todo.dueDate ?? max(todo.createdDate, todo.modifiedDate),
            completedDate: todo.completed ? todo.modifiedDate : nil,
            sourceMeetingID: todo.sourceMeetingID,
            sourceActionItemID: todo.sourceActionItemID,
            owner: todo.owner,
            createdDate: todo.createdDate,
            modifiedDate: todo.modifiedDate
        )
    }

    static func actionLinkedTask(for actionItem: ActionItem, meeting: Meeting, now: Date = Date()) -> TaskItem {
        let deadline = actionItem.deadline?.trimmingCharacters(in: .whitespacesAndNewlines)
        var descriptionParts = ["From meeting: \(meeting.title)"]
        if let owner = actionItem.owner {
            descriptionParts.append("Owner: \(owner)")
        }
        if let deadline, !deadline.isEmpty {
            descriptionParts.append("Deadline: \(deadline)")
        }

        let status: Status = actionItem.isCompleted ? .completed : .open
        return TaskItem(
            title: actionItem.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Untitled action item"
                : actionItem.task,
            description: descriptionParts.joined(separator: "\n"),
            status: status,
            workDate: dueDate(from: deadline) ?? meeting.date,
            completedDate: status == .completed ? now : nil,
            sourceMeetingID: meeting.id,
            sourceActionItemID: actionItem.id,
            owner: actionItem.owner,
            createdDate: now,
            modifiedDate: now
        )
    }

    static func mergingActionLinkedTasks(existing: [TaskItem], meeting: Meeting, now: Date = Date()) -> [TaskItem] {
        var merged = existing
        let meetingLinkedIndexes = linkedIndexes(for: meeting.id, in: merged)
        let linkedIndexesByKey = linkIndexes(in: merged)
        var usedIndexes = Set<Int>()

        for actionItem in meeting.summary.actionItems {
            guard !actionItem.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let key = linkKey(meetingID: meeting.id, actionItemID: actionItem.id)
            let desired = actionLinkedTask(for: actionItem, meeting: meeting, now: now)

            if let existingIndex = linkedIndexesByKey[key], !usedIndexes.contains(existingIndex) {
                merged[existingIndex] = merged[existingIndex].refreshingSourceFields(from: desired, now: now)
                usedIndexes.insert(existingIndex)
            } else if let existingIndex = meetingLinkedIndexes.first(where: { !usedIndexes.contains($0) }) {
                merged[existingIndex] = merged[existingIndex].refreshingSourceFields(from: desired, now: now)
                usedIndexes.insert(existingIndex)
            } else {
                merged.insert(desired, at: 0)
            }
        }

        for existingIndex in meetingLinkedIndexes where !usedIndexes.contains(existingIndex) {
            merged[existingIndex] = merged[existingIndex].unlinkedFromSource(now: now)
        }

        return merged
    }

    private func refreshingSourceFields(from source: TaskItem, now: Date) -> TaskItem {
        var refreshed = self
        refreshed.title = source.title
        refreshed.description = source.description
        refreshed.workDate = source.workDate
        refreshed.sourceMeetingID = source.sourceMeetingID
        refreshed.sourceActionItemID = source.sourceActionItemID
        refreshed.owner = source.owner
        if refreshed != self {
            refreshed.modifiedDate = now
        }
        return refreshed
    }

    private func unlinkedFromSource(now: Date) -> TaskItem {
        guard sourceMeetingID != nil || sourceActionItemID != nil else { return self }
        var unlinked = self
        unlinked.sourceMeetingID = nil
        unlinked.sourceActionItemID = nil
        unlinked.modifiedDate = now
        return unlinked
    }

    static func linkKey(meetingID: UUID, actionItemID: String) -> String {
        "\(meetingID.uuidString.lowercased())|\(actionItemID)"
    }

    private static func linkKey(for task: TaskItem) -> String? {
        guard let sourceMeetingID = task.sourceMeetingID,
              let sourceActionItemID = task.sourceActionItemID else { return nil }
        return linkKey(meetingID: sourceMeetingID, actionItemID: sourceActionItemID)
    }

    private static func linkIndexes(in tasks: [TaskItem]) -> [String: Int] {
        var indexes: [String: Int] = [:]
        for (index, task) in tasks.enumerated() {
            guard let key = linkKey(for: task), indexes[key] == nil else { continue }
            indexes[key] = index
        }
        return indexes
    }

    private static func linkedIndexes(for meetingID: UUID, in tasks: [TaskItem]) -> [Int] {
        tasks.indices.filter { tasks[$0].sourceMeetingID == meetingID }
    }

    private static func dueDate(from deadline: String?) -> Date? {
        guard let deadline, !deadline.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: deadline) {
            return date
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dayFormatter.date(from: deadline) {
            return date
        }

        let mediumFormatter = DateFormatter()
        mediumFormatter.locale = Locale(identifier: "en_US_POSIX")
        mediumFormatter.dateStyle = .medium
        mediumFormatter.timeStyle = .none
        mediumFormatter.isLenient = true
        return mediumFormatter.date(from: deadline)
    }
}

struct TaskTodoSplit: Equatable {
    var todos: [TodoItem]
    var tasks: [TaskItem]
}

enum TaskTodoClassifier {
    static func splitLegacyTodos(_ todos: [TodoItem]) -> TaskTodoSplit {
        var keptTodos: [TodoItem] = []
        var promotedTasks: [TaskItem] = []

        for todo in todos {
            if shouldPromoteToTask(todo) {
                promotedTasks.append(TaskItem.fromLegacyTodo(todo))
            } else {
                keptTodos.append(todo)
            }
        }

        return TaskTodoSplit(todos: keptTodos, tasks: promotedTasks)
    }

    static func shouldPromoteToTask(_ todo: TodoItem) -> Bool {
        if todo.isActionLinked {
            return true
        }
        if hasMeaningfulDescription(todo.description) {
            return true
        }
        if todo.completed && (todo.dueDate == nil || !todo.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return true
        }
        return false
    }

    private static func hasMeaningfulDescription(_ description: String) -> Bool {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\n") {
            return true
        }
        return trimmed.count >= 40
    }
}
