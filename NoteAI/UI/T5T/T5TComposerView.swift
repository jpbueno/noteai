import SwiftUI

/// Main T5T report composer — task selection, LLM generation, section editing, export.
struct T5TComposerView: View {
    @ObservedObject var meetingManager: MeetingManager
    @Binding var report: T5TReport
    @ObservedObject var ttsService: TextToSpeechService

    @State private var periodStart: Date
    @State private var periodEnd: Date
    @State private var selectedTaskIDs: Set<UUID>
    @State private var showConfigSheet = false
    @State private var showTaskSelector = true
    @State private var editableConfig: T5TConfig
    @State private var generationError: String?
    @State private var mailDraftError: String?

    init(meetingManager: MeetingManager, report: Binding<T5TReport>, ttsService: TextToSpeechService) {
        self.meetingManager = meetingManager
        self._report = report
        self.ttsService = ttsService
        // Default: if the report has no explicit task selection yet, auto-select
        // all durable tasks in the period for T5T source material.
        let explicitTasks = report.wrappedValue.taskIDs.isEmpty
            ? report.wrappedValue.todoIDs
            : report.wrappedValue.taskIDs
        if explicitTasks.isEmpty {
            let inRange = meetingManager.tasksInRange(
                start: report.wrappedValue.periodStart,
                end: report.wrappedValue.periodEnd
            )
            self._selectedTaskIDs = State(initialValue: Set(inRange.map(\.id)))
        } else {
            self._selectedTaskIDs = State(initialValue: Set(explicitTasks))
        }
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
                    periodControls
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
        .alert(
            "Could not open formatted Outlook draft",
            isPresented: Binding(
                get: { mailDraftError != nil },
                set: { isPresented in
                    if !isPresented {
                        mailDraftError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(mailDraftError ?? "")
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
                .font(.system(size: Theme.pageTitleSize, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .onChange(of: report.title) { _, _ in
                    meetingManager.updateT5TReport(report)
                }

            HStack(spacing: 16) {
                Label(report.periodLabel, systemImage: "calendar")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Label("\(selectedTaskIDs.count) tasks", systemImage: "checklist")
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

    // MARK: - Period Selection

    private var periodControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("From")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    DatePicker("", selection: $periodStart, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                HStack(spacing: 6) {
                    Text("To")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    DatePicker("", selection: $periodEnd, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                Spacer()
            }

            HStack(spacing: 8) {
                quickRangeButton("Last 2 weeks") {
                    periodEnd = Date()
                    periodStart = Calendar.current.date(byAdding: .day, value: -14, to: periodEnd)!
                }
                quickRangeButton("This month") {
                    periodEnd = Date()
                    periodStart = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date()))!
                }
                Spacer()
            }
        }
        .onChange(of: periodStart) { _, _ in
            syncPeriodAndTaskSelection()
        }
        .onChange(of: periodEnd) { _, _ in
            syncPeriodAndTaskSelection()
        }
    }

    private func quickRangeButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Task Selection (primary T5T input)

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
                        .font(.system(size: 16, weight: .semibold))
                    Text("(\(selectedTaskIDs.count) selected)")
                        .font(.system(size: 13))
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
                    report.todoIDs = Array(newValue)
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
                    .disabled(selectedTaskIDs.isEmpty)
                }

                Spacer()

                if !report.sections.isEmpty {
                    ReadAloudButton(tts: ttsService, text: report.emailBody)

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
                report.periodStart = periodStart
                report.periodEnd = periodEnd
                report.meetingIDs = []
                report.noteIDs = []
                report.taskIDs = Array(selectedTaskIDs)
                report.todoIDs = Array(selectedTaskIDs)
                let updated = try await meetingManager.regenerateT5T(report: report)
                report = updated
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
        let result = T5TMailDraft.open(for: report)
        if case .outlookAutomationFailed(let message) = result {
            mailDraftError = message
        }
    }

    private func syncPeriodAndTaskSelection() {
        report.periodStart = periodStart
        report.periodEnd = periodEnd
        let inRange = meetingManager.tasksInRange(start: periodStart, end: periodEnd)
        selectedTaskIDs = Set(inRange.map(\.id))
        report.taskIDs = Array(selectedTaskIDs)
        report.todoIDs = Array(selectedTaskIDs)
        meetingManager.updateT5TReport(report)
    }
}
