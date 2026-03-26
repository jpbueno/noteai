import SwiftUI

/// Notion-style note editor — big title, tag bar, markdown editor with preview.
struct NotePageView: View {
    @Binding var note: Note
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var ttsService: TextToSpeechService

    @State private var newTag = ""
    @State private var showTagField = false

    /// Debounce auto-save so we don't write to SQLite on every keystroke
    @State private var saveWork: DispatchWorkItem?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader
                    tagBar
                    Divider().foregroundStyle(Theme.border).padding(.vertical, 12)
                    editorToolbar
                    Divider().foregroundStyle(Theme.border).padding(.bottom, 8)
                    editorContent
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

    // MARK: - Header

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTE")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.sectionHeader)
                .textCase(.uppercase)

            TextField("Untitled", text: $note.title)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.pageTitleSize, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .onChange(of: note.title) { _, _ in
                    saveImmediately()
                }

            HStack(spacing: 12) {
                Label("Created \(note.formattedCreatedDate)", systemImage: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                if note.modifiedDate != note.createdDate {
                    Label("Modified \(note.formattedModifiedDate)", systemImage: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let meetingID = note.sourceMeetingID,
                   let meeting = meetingManager.meetings.first(where: { $0.id == meetingID }) {
                    Label("From: \(meeting.title)", systemImage: "waveform")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Tags

    private var tagBar: some View {
        HStack(spacing: 6) {
            ForEach(note.tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        note.tags.removeAll { $0 == tag }
                        saveImmediately()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 4))
            }

            if showTagField {
                TextField("Tag name", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 80)
                    .onSubmit {
                        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !note.tags.contains(trimmed) {
                            note.tags.append(trimmed)
                            saveImmediately()
                        }
                        newTag = ""
                        showTagField = false
                    }
            }

            Button {
                showTagField.toggle()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(4)
                    .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Editor Toolbar

    private var editorToolbar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                ReadAloudButton(tts: ttsService, text: note.content)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.content, forType: .string)
                } label: {
                    Label("Copy Markdown", systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 4)
            TTSPlayerView(tts: ttsService)
        }
    }

    // MARK: - Editor Content

    private var editorContent: some View {
        RichMarkdownEditor(text: $note.content, onChange: { debouncedSave() })
            .frame(minHeight: 400)
    }

    // MARK: - Save

    private func debouncedSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [note] in
            Task { @MainActor in
                meetingManager.updateNote(note)
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveImmediately() {
        saveWork?.cancel()
        meetingManager.updateNote(note)
    }

    private func insertText(_ text: String, offset: Int = 0) {
        // Append at cursor position (simplified: append to end)
        note.content += text
        debouncedSave()
    }

}
