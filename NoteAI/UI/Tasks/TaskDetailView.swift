import SwiftUI

/// Detail editor for a durable TaskItem. Tasks are work records that can feed
/// T5T reports; todos remain lightweight reminders.
struct TaskDetailView: View {
    @Binding var task: TaskItem
    @ObservedObject var meetingManager: MeetingManager

    @State private var titleDraft: String = ""
    @State private var descriptionDraft: String = ""
    @State private var hasWorkDate: Bool = false
    @State private var workDateDraft: Date = Date()
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
                    Text("WORK DATE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .tracking(0.5)
                    HStack {
                        Toggle(isOn: $hasWorkDate) {
                            Text(hasWorkDate ? "Tracked work date" : "No work date")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        if hasWorkDate {
                            DatePicker("", selection: $workDateDraft, displayedComponents: .date)
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
                        .frame(minHeight: 180)
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
        .onAppear { loadFromTask() }
        .onChange(of: task.id) { _, _ in loadFromTask(force: true) }
        .onChange(of: titleDraft) { _, _ in scheduleSave() }
        .onChange(of: descriptionDraft) { _, _ in scheduleSave() }
        .onChange(of: hasWorkDate) { _, _ in scheduleSave() }
        .onChange(of: workDateDraft) { _, _ in scheduleSave() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                toggleCompletion()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    Text(task.isCompleted ? "Completed" : "Mark complete")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(task.isCompleted ? Color(hex: "3BB273") : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(role: .destructive) {
                meetingManager.deleteTask(task)
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

    private func toggleCompletion() {
        meetingManager.toggleTaskCompletion(task)
    }

    private func loadFromTask(force: Bool = false) {
        if didLoad && !force { return }
        titleDraft = task.title
        descriptionDraft = task.description
        if let workDate = task.workDate {
            hasWorkDate = true
            workDateDraft = workDate
        } else {
            hasWorkDate = false
            workDateDraft = Date()
        }
        didLoad = true
    }

    private func scheduleSave() {
        guard didLoad else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            commit()
        }
    }

    private func commit() {
        var updated = task
        updated.title = titleDraft
        updated.description = descriptionDraft
        updated.workDate = hasWorkDate ? workDateDraft : nil
        updated.modifiedDate = Date()
        meetingManager.updateTask(updated)
        task = updated
    }
}
