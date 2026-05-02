import SwiftUI

/// Renders a meeting as a Notion-style flowing document page
/// with subtle underline tabs to switch between Summary, Transcript, and Markdown.
struct NotionPageView: View {
    @State var meeting: Meeting
    var summarizationStatus: MeetingManager.SummarizationStatus = .idle
    var meetingManager: MeetingManager?
    @ObservedObject var ttsService: TextToSpeechService
    @State private var selectedTab: PageTab = .summary
    @State private var followUpDraft: String?
    @State private var isGeneratingFollowUp = false
    @State private var followUpError: String?
    @State private var isRegeneratingSummary = false
    @State private var regeneratingSection: MeetingSummarySection?
    @State private var sectionRegenerateError: (section: MeetingSummarySection, message: String)?

    enum PageTab: String, CaseIterable {
        case summary = "Summary"
        case transcript = "Transcript"
        case markdown = "Markdown"
    }

    var body: some View {
        if selectedTab == .markdown {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    tabBar
                }
                .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 48)
                .frame(maxWidth: .infinity, alignment: .leading)

                MarkdownEditorView(meeting: $meeting)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, Theme.pagePadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.contentBG)
        } else {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        pageHeader
                        tabBar
                        tabContent
                    }
                    .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 48)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
            .background(Theme.contentBG)
        }
    }

    // MARK: - Header

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MEETING")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.sectionHeader)
                .textCase(.uppercase)

            Text(meeting.title)
                .font(.system(size: Theme.pageTitleSize, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 4)

            HStack(spacing: 16) {
                Text(meeting.date.formatted(date: .long, time: .shortened))
                Text("·")
                Text(meeting.formattedDuration)
                Text("·")
                Text("\(meeting.transcript.count) segments")

                Spacer()

                if let manager = meetingManager {
                    Button {
                        let note = manager.createNoteFromMeeting(meeting)
                        NotificationCenter.default.post(name: .navigateToNote, object: note.id)
                    } label: {
                        Label("Save to Note", systemImage: "note.text.badge.plus")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)

                    ReadAloudButton(tts: ttsService, text: meetingSummaryText)
                }
            }
            .font(.system(size: Theme.smallSize))
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Tab Bar (Notion-style underline)

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(PageTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Text(tab.rawValue)
                                .font(.system(size: 14, weight: selectedTab == tab ? .medium : .regular))
                                .foregroundStyle(selectedTab == tab ? Theme.textPrimary : Theme.textTertiary)

                            Rectangle()
                                .fill(selectedTab == tab ? Theme.textPrimary : Color.clear)
                                .frame(height: 1.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 24)
                }
                Spacer()
            }

            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        }
        .padding(.bottom, 24)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .summary:
            summaryContent
        case .transcript:
            transcriptContent
        case .markdown:
            MarkdownEditorView(meeting: $meeting)
        }
    }

    // MARK: - Summary (flowing document)

    @ViewBuilder
    private var summaryContent: some View {
        if case .summarizing(let model) = summarizationStatus {
            summarizingIndicator(model: model)
        } else if case .failed(let error) = summarizationStatus {
            summarizationErrorView(error: error)
        } else if meeting.summary.isEmpty && meeting.summary.wasSummarized {
            // Summarization ran but transcript had no meeting content
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                    Text("No meeting content detected")
                        .font(.system(size: Theme.bodySize, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text("The AI analyzed the transcript but didn't find decisions, action items, or discussion topics. This can happen if the audio was music, background noise, or a non-meeting recording.")
                    .font(.system(size: Theme.smallSize))
                    .foregroundStyle(Theme.textTertiary)
                    .lineSpacing(3)

                retryButton
            }
            .padding(.top, 8)
        } else if meeting.summary.isEmpty {
            // Never summarized
            VStack(alignment: .leading, spacing: 16) {
                Text("No summary available")
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(Theme.textTertiary)

                if isRegeneratingSummary {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Generating summary...")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    retryButton
                }
            }
            .padding(.top, 8)
        } else {
            editableTextSection(.decisions)
            verticalSpace()

            editableActionItemsSection
            verticalSpace()

            editableTextSection(.topics)
            verticalSpace()

            editableTextSection(.openQuestions)
            verticalSpace()

            linkedTodosSection

            // Follow-up email section
            followUpSection
        }
    }

    // MARK: - Transcript (flowing document)

    @ViewBuilder
    private var transcriptContent: some View {
        if meeting.transcript.isEmpty {
            Text("No transcript available")
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 8)
        } else {
            ForEach(meeting.transcript) { segment in
                transcriptLine(segment)
            }
        }
    }

    // MARK: - Notion-style blocks

    private func heading2(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Theme.h2Size, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.top, 8)
            .padding(.bottom, 8)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("•")
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
        }
        .padding(.leading, 4)
        .padding(.vertical, 3)
    }

    private func summarySectionHeader(_ section: MeetingSummarySection) -> some View {
        HStack(spacing: 10) {
            heading2(section.title)

            let metadata = meeting.summary.metadata(for: section)
            Text(metadata.state == .userEdited ? "Edited" : "Generated")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(metadata.state == .userEdited ? Theme.textSecondary : Theme.textTertiary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 5))

            Spacer()

            Button {
                regenerateSection(section)
            } label: {
                HStack(spacing: 5) {
                    if regeneratingSection == section {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                    Text("Regenerate")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .disabled(regeneratingSection != nil)
        }
    }

    private func editableTextSection(_ section: MeetingSummarySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            summarySectionHeader(section)

            TextEditor(text: Binding(
                get: { textValues(for: section).joined(separator: "\n") },
                set: { updateTextSection(section, text: $0) }
            ))
            .font(.system(size: Theme.bodySize))
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 76)
            .padding(10)
            .background(Theme.sidebarBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            sectionErrorText(for: section)
        }
    }

    private var editableActionItemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            summarySectionHeader(.actionItems)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(meeting.summary.actionItems) { item in
                    actionItemEditorRow(item)
                }

                Button {
                    addActionItem()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text("Add Action Item")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            .padding(10)
            .background(Theme.sidebarBG.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            sectionErrorText(for: .actionItems)
        }
    }

    private func actionItemEditorRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                meetingManager?.toggleActionItem(meetingId: meeting.id, actionItemId: item.id)
                if let idx = meeting.summary.actionItems.firstIndex(where: { $0.id == item.id }) {
                    meeting.summary.actionItems[idx].isCompleted.toggle()
                }
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isCompleted ? Color(hex: "2ECC71") : Theme.textTertiary)
                    .padding(.top, 6)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Action item", text: actionItemTaskBinding(id: item.id))
                    .textFieldStyle(.plain)
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(item.isCompleted ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(item.isCompleted, color: Theme.textTertiary)

                HStack(spacing: 8) {
                    TextField("Owner", text: actionItemOwnerBinding(id: item.id))
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.smallSize))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: 160)

                    TextField("Deadline", text: actionItemDeadlineBinding(id: item.id))
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.smallSize))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: 180)
                }
            }

            Spacer()

            Button {
                deleteActionItem(id: item.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var linkedTodosSection: some View {
        let linkedTodos = meetingManager?.todosLinked(to: meeting.id) ?? []
        if !linkedTodos.isEmpty {
            heading2("Linked Todos")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(linkedTodos) { todo in
                    linkedTodoRow(todo)
                }
            }
            verticalSpace()
        }
    }

    private func linkedTodoRow(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                meetingManager?.toggleTodoCompletion(todo)
            } label: {
                Image(systemName: todo.completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(todo.completed ? Theme.success : Theme.textTertiary)
                    .padding(.top, 1)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title.isEmpty ? "Untitled todo" : todo.title)
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(todo.completed ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(todo.completed, color: Theme.textTertiary)
                    .lineSpacing(4)

                HStack(spacing: 8) {
                    if let owner = todo.owner {
                        Text("@\(owner)")
                            .font(.system(size: Theme.smallSize))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let label = todo.dueDateLabel {
                        Text(label)
                            .font(.system(size: Theme.smallSize))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
        .padding(.leading, 4)
        .padding(.vertical, 3)
    }

    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                meetingManager?.toggleActionItem(meetingId: meeting.id, actionItemId: item.id)
                // Update local state
                if let idx = meeting.summary.actionItems.firstIndex(where: { $0.id == item.id }) {
                    meeting.summary.actionItems[idx].isCompleted.toggle()
                }
            } label: {
                Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isCompleted ? Color(hex: "2ECC71") : Theme.textTertiary)
                    .padding(.top, 1)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.task)
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(item.isCompleted ? Theme.textTertiary : Theme.textPrimary)
                    .strikethrough(item.isCompleted, color: Theme.textTertiary)
                    .textSelection(.enabled)
                    .lineSpacing(4)

                if item.owner != nil || item.deadline != nil {
                    HStack(spacing: 8) {
                        if let owner = item.owner {
                            Text("@\(owner)")
                                .font(.system(size: Theme.smallSize))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let deadline = item.deadline {
                            Text(deadline)
                                .font(.system(size: Theme.smallSize))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(.leading, 4)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func sectionErrorText(for section: MeetingSummarySection) -> some View {
        if let error = sectionRegenerateError, error.section == section {
            Text(error.message)
                .font(.system(size: Theme.smallSize))
                .foregroundStyle(.red)
        }
    }

    private func textValues(for section: MeetingSummarySection) -> [String] {
        switch section {
        case .decisions:
            return meeting.summary.decisions
        case .topics:
            return meeting.summary.topics
        case .openQuestions:
            return meeting.summary.openQuestions
        case .actionItems:
            return meeting.summary.actionItems.map(\.task)
        }
    }

    private func updateTextSection(_ section: MeetingSummarySection, text: String) {
        let values = Self.summaryLines(from: text)
        let content: MeetingSummarySectionContent

        switch section {
        case .decisions:
            content = .decisions(values)
        case .topics:
            content = .topics(values)
        case .openQuestions:
            content = .openQuestions(values)
        case .actionItems:
            return
        }

        if let manager = meetingManager {
            meeting = manager.updateSummarySection(section, content: content, meeting: meeting)
        } else {
            meeting.summary.replace(section, with: content, state: .userEdited)
        }
    }

    private func actionItemTaskBinding(id: String) -> Binding<String> {
        Binding(
            get: { actionItem(id: id)?.task ?? "" },
            set: { newValue in
                updateActionItem(id: id) { item in
                    item.task = newValue
                }
            }
        )
    }

    private func actionItemOwnerBinding(id: String) -> Binding<String> {
        Binding(
            get: { actionItem(id: id)?.owner ?? "" },
            set: { newValue in
                updateActionItem(id: id) { item in
                    item.owner = Self.trimmedOptional(newValue)
                }
            }
        )
    }

    private func actionItemDeadlineBinding(id: String) -> Binding<String> {
        Binding(
            get: { actionItem(id: id)?.deadline ?? "" },
            set: { newValue in
                updateActionItem(id: id) { item in
                    item.deadline = Self.trimmedOptional(newValue)
                }
            }
        )
    }

    private func actionItem(id: String) -> ActionItem? {
        meeting.summary.actionItems.first { $0.id == id }
    }

    private func updateActionItem(id: String, mutate: (inout ActionItem) -> Void) {
        guard let index = meeting.summary.actionItems.firstIndex(where: { $0.id == id }) else { return }
        mutate(&meeting.summary.actionItems[index])
        persistActionItems()
    }

    private func addActionItem() {
        meeting.summary.actionItems.append(ActionItem(id: "manual-\(UUID().uuidString)", task: ""))
        persistActionItems()
    }

    private func deleteActionItem(id: String) {
        meeting.summary.actionItems.removeAll { $0.id == id }
        persistActionItems()
    }

    private func persistActionItems() {
        let content = MeetingSummarySectionContent.actionItems(meeting.summary.actionItems)
        if let manager = meetingManager {
            meeting = manager.updateSummarySection(.actionItems, content: content, meeting: meeting)
        } else {
            meeting.summary.replace(.actionItems, with: content, state: .userEdited)
        }
    }

    private static func summaryLines(from text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func trimmedOptional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func transcriptLine(_ segment: TranscriptSegment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            TextField("Speaker", text: speakerNameBinding(for: segment))
                .textFieldStyle(.plain)
                .font(.system(size: Theme.smallSize, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 120)
                .padding(.top, 1)

            Text(segment.text)
                .font(.system(size: Theme.bodySize))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(4)
        }
        .padding(.vertical, 4)
    }

    private func speakerNameBinding(for segment: TranscriptSegment) -> Binding<String> {
        let speakerID = meeting.speakerID(for: segment)
        return Binding(
            get: { meeting.speakerDisplayName(for: segment) },
            set: { newValue in
                updateSpeakerLabel(speakerID: speakerID, displayName: newValue)
            }
        )
    }

    private func updateSpeakerLabel(speakerID: String, displayName: String) {
        if let manager = meetingManager {
            meeting = manager.updateSpeakerLabel(meeting: meeting, speakerID: speakerID, displayName: displayName)
        } else {
            meeting.setSpeakerLabel(speakerID: speakerID, displayName: displayName)
        }
    }

    private func verticalSpace() -> some View {
        Spacer().frame(height: 16)
    }

    // MARK: - Follow-up email

    @ViewBuilder
    private var followUpSection: some View {
        Divider()
            .foregroundStyle(Theme.border)
            .padding(.vertical, 16)

        if let draft = followUpDraft {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    heading2("Follow-up Email Draft")
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)

                    Button {
                        followUpDraft = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textTertiary)
                }

                Text(draft)
                    .font(.system(size: Theme.bodySize))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            HStack(spacing: 12) {
                Button {
                    generateFollowUp()
                } label: {
                    HStack(spacing: 6) {
                        if isGeneratingFollowUp {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "envelope")
                                .font(.system(size: 13))
                        }
                        Text(isGeneratingFollowUp ? "Drafting..." : "Draft follow-up email")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .disabled(isGeneratingFollowUp)

                if let error = followUpError {
                    Text(error)
                        .font(.system(size: Theme.smallSize))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @State private var regenerateError: String?

    @ViewBuilder
    private var retryButton: some View {
        if isRegeneratingSummary {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Generating summary...")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
            }
        } else {
            Button {
                regenerateSummary()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                    Text("Retry Summary")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)

            if let error = regenerateError {
                Text(error)
                    .font(.system(size: Theme.smallSize))
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
    }

    private func regenerateSummary() {
        guard let manager = meetingManager else {
            print("[NotionPageView] meetingManager is nil — cannot regenerate")
            regenerateError = "Internal error: meeting manager unavailable"
            return
        }
        isRegeneratingSummary = true
        regenerateError = nil

        Task { @MainActor in
            do {
                print("[NotionPageView] Starting resummarize for meeting \(meeting.id)")
                let updatedMeeting = try await manager.resummarize(meeting: meeting)
                print("[NotionPageView] Resummarize succeeded, summary isEmpty=\(updatedMeeting.summary.isEmpty)")
                meeting = updatedMeeting
                isRegeneratingSummary = false
            } catch {
                print("[NotionPageView] Resummarize failed: \(error)")
                regenerateError = error.localizedDescription
                isRegeneratingSummary = false
            }
        }
    }

    private func regenerateSection(_ section: MeetingSummarySection) {
        guard let manager = meetingManager else {
            sectionRegenerateError = (section, "Internal error: meeting manager unavailable")
            return
        }
        regeneratingSection = section
        sectionRegenerateError = nil

        Task { @MainActor in
            do {
                let updatedMeeting = try await manager.regenerateSummarySection(section, meeting: meeting)
                meeting = updatedMeeting
                regeneratingSection = nil
            } catch {
                sectionRegenerateError = (section, error.localizedDescription)
                regeneratingSection = nil
            }
        }
    }

    private func generateFollowUp() {
        guard let manager = meetingManager else { return }
        isGeneratingFollowUp = true
        followUpError = nil

        Task {
            do {
                let draft = try await manager.draftFollowUp(for: meeting)
                await MainActor.run {
                    followUpDraft = draft
                    isGeneratingFollowUp = false
                }
            } catch {
                await MainActor.run {
                    followUpError = error.localizedDescription
                    isGeneratingFollowUp = false
                }
            }
        }
    }

    // MARK: - Summarization progress

    private func summarizingIndicator(model: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Generating summary...")
                        .font(.system(size: Theme.bodySize, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Using \(model)")
                        .font(.system(size: Theme.smallSize))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 8)
        }
    }

    private func summarizationErrorView(error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Summarization failed")
                    .font(.system(size: Theme.bodySize, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(error)
                .font(.system(size: Theme.smallSize))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
    }

    private var meetingSummaryText: String {
        var parts: [String] = [meeting.title]
        if !meeting.summary.decisions.isEmpty { parts.append("Key Decisions: " + meeting.summary.decisions.joined(separator: ". ")) }
        if !meeting.summary.actionItems.isEmpty { parts.append("Action Items: " + meeting.summary.actionItems.map(\.task).joined(separator: ". ")) }
        if !meeting.summary.topics.isEmpty { parts.append("Topics: " + meeting.summary.topics.joined(separator: ". ")) }
        if !meeting.summary.openQuestions.isEmpty { parts.append("Open Questions: " + meeting.summary.openQuestions.joined(separator: ". ")) }
        return parts.joined(separator: ". ")
    }
}
