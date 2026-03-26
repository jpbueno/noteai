import SwiftUI

/// Main T5T report composer — date selection, meeting picker, LLM generation, section editing, export.
struct T5TComposerView: View {
    @ObservedObject var meetingManager: MeetingManager
    @Binding var report: T5TReport

    @State private var showMeetingSelector = true
    @State private var selectedMeetingIDs: Set<UUID>
    @State private var periodStart: Date
    @State private var periodEnd: Date
    @State private var selectedNoteIDs: Set<UUID>
    @State private var selectedTaskIDs: Set<UUID>
    @State private var showConfigSheet = false
    @State private var showNoteSelector = false
    @State private var showTaskSelector = false
    @State private var editableConfig: T5TConfig
    @State private var generationError: String?

    init(meetingManager: MeetingManager, report: Binding<T5TReport>) {
        self.meetingManager = meetingManager
        self._report = report
        self._selectedMeetingIDs = State(initialValue: Set(report.wrappedValue.meetingIDs))
        self._selectedNoteIDs = State(initialValue: Set(report.wrappedValue.noteIDs))
        self._selectedTaskIDs = State(initialValue: Set(report.wrappedValue.taskIDs))
        self._periodStart = State(initialValue: report.wrappedValue.periodStart)
        self._periodEnd = State(initialValue: report.wrappedValue.periodEnd)
        self._editableConfig = State(initialValue: meetingManager.t5tConfig)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection
                    Divider().foregroundStyle(Theme.border).padding(.vertical, 16)
                    meetingSection
                    noteSection
                    taskSection
                    Divider().foregroundStyle(Theme.border).padding(.vertical, 16)
                    actionBar
                    if !report.sections.isEmpty {
                        Divider().foregroundStyle(Theme.border).padding(.vertical, 16)
                        sectionsEditor
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.contentBG)
        .sheet(isPresented: $showConfigSheet) {
            T5TConfigSheet(config: $editableConfig) { config in
                meetingManager.saveT5TConfig(config)
                report.title = config.subjectLine
                meetingManager.updateT5TReport(report)
            }
        }
        .onAppear {
            if !meetingManager.t5tConfig.isComplete && report.sections.isEmpty {
                showConfigSheet = true
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("T5T Report")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.sectionHeader)
                    .textCase(.uppercase)
                Spacer()
                statusBadge
            }

            TextField("Subject line", text: $report.title)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.pageTitleSize, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .onChange(of: report.title) { _, _ in
                    meetingManager.updateT5TReport(report)
                }

            HStack(spacing: 16) {
                Label(report.periodLabel, systemImage: "calendar")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Label("\(selectedMeetingIDs.count) meetings", systemImage: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Configure T5T") { showConfigSheet = true }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .buttonStyle(.plain)
            }
        }
    }

    private var statusBadge: some View {
        Text(report.status == .draft ? "Draft" : "Finalized")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(report.status == .draft ? Color.orange : Color.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (report.status == .draft ? Color.orange : Color.green).opacity(0.15),
                in: RoundedRectangle(cornerRadius: 4)
            )
    }

    // MARK: - Meeting Selection

    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMeetingSelector.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showMeetingSelector ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Source Meetings")
                        .font(.system(size: 13, weight: .semibold))
                    Text("(\(selectedMeetingIDs.count) selected)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if showMeetingSelector {
                MeetingSelectorView(
                    meetings: meetingManager.meetings,
                    selectedIDs: $selectedMeetingIDs,
                    periodStart: $periodStart,
                    periodEnd: $periodEnd
                )
                .onChange(of: selectedMeetingIDs) { _, newValue in
                    report.meetingIDs = Array(newValue)
                    report.periodStart = periodStart
                    report.periodEnd = periodEnd
                    meetingManager.updateT5TReport(report)
                }
                .onChange(of: periodStart) { _, _ in
                    report.periodStart = periodStart
                    // Auto-select meetings in new range
                    let inRange = meetingManager.meetingsInRange(start: periodStart, end: periodEnd)
                    selectedMeetingIDs = Set(inRange.map(\.id))
                }
                .onChange(of: periodEnd) { _, _ in
                    report.periodEnd = periodEnd
                    let inRange = meetingManager.meetingsInRange(start: periodStart, end: periodEnd)
                    selectedMeetingIDs = Set(inRange.map(\.id))
                }
            }
        }
    }

    // MARK: - Action Bar

    // MARK: - Note Selection

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showNoteSelector.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showNoteSelector ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Source Notes")
                        .font(.system(size: 13, weight: .semibold))
                    Text("(\(selectedNoteIDs.count) selected)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if showNoteSelector {
                NoteSelectorView(
                    notes: meetingManager.notes,
                    selectedIDs: $selectedNoteIDs,
                    periodStart: periodStart,
                    periodEnd: periodEnd
                )
                .onChange(of: selectedNoteIDs) { _, newValue in
                    report.noteIDs = Array(newValue)
                    meetingManager.updateT5TReport(report)
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Task Selection

    private var taskSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTaskSelector.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showTaskSelector ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Source Tasks")
                        .font(.system(size: 13, weight: .semibold))
                    Text("(\(selectedTaskIDs.count) selected)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if showTaskSelector {
                TaskSelectorView(
                    tasks: meetingManager.tasks,
                    selectedIDs: $selectedTaskIDs,
                    periodStart: periodStart,
                    periodEnd: periodEnd
                )
                .onChange(of: selectedTaskIDs) { _, newValue in
                    report.taskIDs = Array(newValue)
                    meetingManager.updateT5TReport(report)
                }
            }
        }
        .padding(.top, 8)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                if case .generating(let model) = meetingManager.t5tGenerationStatus {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating with \(model)...")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Button {
                        generateT5T()
                    } label: {
                        Label(report.sections.isEmpty ? "Generate T5T" : "Regenerate", systemImage: "sparkles")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedMeetingIDs.isEmpty)
                }

                Spacer()

                if !report.sections.isEmpty {
                    Button {
                        copyToClipboard()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)

                    Button {
                        openInMail()
                    } label: {
                        Label("Open in Mail", systemImage: "envelope")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                }
            }

            if let error = generationError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Sections Editor

    private var sectionsEditor: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !report.sections.insights.isEmpty {
                sectionBlock(
                    title: "Insights, Management Escalations & Help Needed, Market & Competition",
                    entries: $report.sections.insights
                )
            }

            if !report.sections.accountUpdates.isEmpty {
                sectionBlock(
                    title: "Industry Business Development / Account Updates",
                    entries: $report.sections.accountUpdates
                )
            }

            if !report.sections.futurePlans.isEmpty {
                sectionBlock(
                    title: "Future Plans",
                    entries: $report.sections.futurePlans
                )
            }
        }
    }

    private func sectionBlock(title: String, entries: Binding<[T5TEntry]>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: Theme.h3Size, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    entries.wrappedValue.append(T5TEntry(headline: "", explanation: ""))
                    meetingManager.updateT5TReport(report)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            ForEach(entries) { $entry in
                T5TEntryEditor(entry: $entry) {
                    entries.wrappedValue.removeAll { $0.id == entry.id }
                    meetingManager.updateT5TReport(report)
                }
                .onChange(of: entry) { _, _ in
                    meetingManager.updateT5TReport(report)
                }
            }
        }
    }

    // MARK: - Actions

    private func generateT5T() {
        generationError = nil
        Task {
            do {
                if report.sections.isEmpty {
                    let newReport = try await meetingManager.createT5TReport(
                        periodStart: periodStart,
                        periodEnd: periodEnd,
                        meetingIDs: Array(selectedMeetingIDs),
                        noteIDs: Array(selectedNoteIDs),
                        taskIDs: Array(selectedTaskIDs)
                    )
                    report = newReport
                } else {
                    report.meetingIDs = Array(selectedMeetingIDs)
                    report.noteIDs = Array(selectedNoteIDs)
                    report.taskIDs = Array(selectedTaskIDs)
                    let updated = try await meetingManager.regenerateT5T(report: report)
                    report = updated
                }
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func copyToClipboard() {
        let text = "Subject: \(report.title)\n\n\(report.emailBody)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openInMail() {
        let subject = report.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let body = report.emailBody.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:?subject=\(subject)&body=\(body)") {
            NSWorkspace.shared.open(url)
        }
    }
}
