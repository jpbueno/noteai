import SwiftUI

/// Detail editor for a single TodoItem. Complements the Home dashboard list
/// view; used when a todo is selected in the sidebar.
struct TodoDetailView: View {
    @Binding var todo: TodoItem
    @ObservedObject var meetingManager: MeetingManager

    @State private var titleDraft: String = ""
    @State private var descriptionDraft: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDateDraft: Date = Date()
    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(alignment: .leading, spacing: 6) {
                    Text("TITLE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .tracking(0.5)
                    TextField("Untitled task", text: $titleDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("DUE DATE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .tracking(0.5)
                    HStack {
                        Toggle(isOn: $hasDueDate) {
                            Text(hasDueDate ? "Has due date" : "No due date")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        if hasDueDate {
                            DatePicker("", selection: $dueDateDraft, displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .labelsHidden()
                        }
                        Spacer()
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("DESCRIPTION")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .tracking(0.5)
                    TextEditor(text: $descriptionDraft)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Theme.sidebarBG.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 840, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.contentBG)
        .onAppear { loadFromTodo() }
        .onChange(of: todo.id) { _, _ in loadFromTodo(force: true) }
        .onChange(of: titleDraft) { _, _ in scheduleSave() }
        .onChange(of: descriptionDraft) { _, _ in scheduleSave() }
        .onChange(of: hasDueDate) { _, _ in scheduleSave() }
        .onChange(of: dueDateDraft) { _, _ in scheduleSave() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                meetingManager.toggleTodoCompletion(todo)
                // Update local binding-driven state so UI reflects change immediately
                todo.completed.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    Text(todo.completed ? "Completed" : "Mark complete")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(todo.completed ? Color(hex: "3BB273") : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(role: .destructive) {
                meetingManager.deleteTodo(todo)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                    Text("Delete")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "E03E3E"))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Load + save

    private func loadFromTodo(force: Bool = false) {
        if didLoad && !force { return }
        titleDraft = todo.title
        descriptionDraft = todo.description
        if let due = todo.dueDate {
            hasDueDate = true
            dueDateDraft = due
        } else {
            hasDueDate = false
            dueDateDraft = Date()
        }
        didLoad = true
    }

    private func scheduleSave() {
        guard didLoad else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s debounce
            if Task.isCancelled { return }
            commit()
        }
    }

    private func commit() {
        var updated = todo
        updated.title = titleDraft
        updated.description = descriptionDraft
        updated.dueDate = hasDueDate ? dueDateDraft : nil
        updated.modifiedDate = Date()
        meetingManager.updateTodo(updated)
        todo = updated
    }
}
