import SwiftUI
import Vision
import AppKit

/// Task detail view with manual editing and AI-powered summarization.
struct TaskDetailView: View {
    @Binding var task: TaskItem
    @ObservedObject var meetingManager: MeetingManager
    @ObservedObject var ttsService: TextToSpeechService
    /// Dedicated engine instance to avoid @MainActor isolation issues
    private let engine = SummarizationEngine()

    @State private var inputText = ""
    @State private var isSummarizing = false
    @State private var summarizeError: String?
    @State private var showRawInput = false
    @State private var showAISummarize = false
    @State private var newTag = ""
    @State private var showTagField = false
    @State private var isDragOver = false
    @State private var saveWork: DispatchWorkItem?
    @State private var pastedImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        taskHeader
                        tagBar
                        Divider().foregroundStyle(Theme.border).padding(.vertical, 16)
                        descriptionSection
                        Divider().foregroundStyle(Theme.border).padding(.vertical, 16)
                        aiSection
                        if !task.rawInput.isEmpty {
                            Divider().foregroundStyle(Theme.border).padding(.vertical, 16)
                            rawInputSection
                        }
                    }
                    .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                    .padding(.horizontal, Theme.pagePadding)
                    .padding(.top, 48)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                }
            }
            TTSPlayerView(tts: ttsService)
        }
        .background(Theme.contentBG)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDragOver) { providers in
            handleImageDrop(providers)
            return true
        }
    }

    // MARK: - Header

    private var taskHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TASK")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.sectionHeader)
                .textCase(.uppercase)

            TextField("Task title", text: $task.title)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.h2Size, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .onChange(of: task.title) { _, _ in saveImmediately() }

            HStack(spacing: 16) {
                Label(task.formattedDate, systemImage: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)

                ReadAloudButton(tts: ttsService, text: "\(task.title). \(task.description)")

                if let meetingID = task.sourceMeetingID,
                   let meeting = meetingManager.meetings.first(where: { $0.id == meetingID }) {
                    Label("From: \(meeting.title)", systemImage: "waveform")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                if let noteID = task.sourceNoteID,
                   let note = meetingManager.notes.first(where: { $0.id == noteID }) {
                    Label("From: \(note.title)", systemImage: "note.text")
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
            ForEach(task.tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Button {
                        task.tags.removeAll { $0 == tag }
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
                TextField("Tag", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 80)
                    .onSubmit {
                        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty && !task.tags.contains(trimmed) {
                            task.tags.append(trimmed)
                            saveImmediately()
                        }
                        newTag = ""
                        showTagField = false
                    }
            }

            Button { showTagField.toggle() } label: {
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

    // MARK: - Description (manual markdown editor)

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.system(size: Theme.h3Size, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            RichMarkdownEditor(text: $task.description, onChange: { debouncedSave() })
                .frame(minHeight: 150)
        }
    }

    // MARK: - AI Summarize (collapsible)

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showAISummarize.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showAISummarize ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                    Text("AI Summarize")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if showAISummarize {
                Text("Paste text, an image, or a screenshot. AI will extract content and generate a task.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)

                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty && pastedImage == nil {
                        Text("Paste text or image here (Cmd+V), or drop an image...")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(12)
                    }
                    if let pastedImage {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Image pasted — extracting text via OCR...")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                                Spacer()
                                Button {
                                    self.pastedImage = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                .buttonStyle(.plain)
                            }
                            Image(nsImage: pastedImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .padding(8)
                    } else {
                        TextEditor(text: $inputText)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                    }
                }
                .frame(minHeight: 100, maxHeight: 200)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isDragOver ? Color.accentColor : Theme.border, lineWidth: isDragOver ? 2 : 1)
                        .background(Theme.hoverBG.cornerRadius(8))
                )
                .onPasteCommand(of: [.png, .tiff, .fileURL]) { providers in
                    handlePastedItems(providers)
                }

                HStack(spacing: 8) {
                    if isSummarizing {
                        ProgressView().controlSize(.small)
                        Text("Summarizing...")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Button { summarize() } label: {
                            Label("Summarize", systemImage: "sparkles")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pastedImage == nil)

                        Button { pasteImageFromClipboard() } label: {
                            Label("Paste Image", systemImage: "doc.on.clipboard")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    if let error = summarizeError {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Raw Input (legacy, collapsed)

    private var rawInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showRawInput.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showRawInput ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Original AI Input")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)

            if showRawInput {
                Text(task.rawInput)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.hoverBG, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Actions

    private func logTask(_ msg: String) {
        #if DEBUG
        let logFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NoteAI/task_summarize.log")
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else { try? data.write(to: logFile) }
        }
        #endif
    }

    private func summarize() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSummarizing = true
        summarizeError = nil
        logTask("summarize() called, text length=\(text.count)")

        // Do the HTTP call directly — bypass all actors
        let prompt = """
        Extract the key accomplishment from this email/message. Write everything in FIRST PERSON ("I configured...", "I resolved...", "I enabled...").

        Return ONLY valid JSON with this exact structure:
        {"title": "...", "description": "..."}

        TITLE: Very short label (3-6 words max). Just enough to identify the task at a glance. Like a filename or tag.
        DESCRIPTION: A 2-3 sentence first-person explanation with full detail — what I accomplished, why it matters, the outcome, names, projects, tools. This is the main content.

        Example output:
        {"title": "JedAI Azure Proxy Fix", "description": "I resolved a missing on_prem_azure/ to azure/ prefix mapping in the NVIDIA inference API proxy for Cadence's JedAI Analog Assistant. This fix enabled Claude Opus 4-6 and other Azure-hosted Anthropic models to appear in the Virtuoso model dropdown, unblocking Cadence's evaluation workflow."}

        Another example:
        {"title": "Crusoe Nemotron Onboarding", "description": "I enabled Crusoe to onboard and benchmark Nemotron by getting them fully onboarded to the Early Access programs (VoiceChat and Nemotron 3 Super), ensuring the right members of their inference team had access and materials to start testing immediately."}

        INPUT:
        \(String(text.prefix(4000)))
        """

        // Read provider config from UserDefaults
        let providerRaw = UserDefaults.standard.string(forKey: "llmProvider") ?? "openrouter"
        let model = UserDefaults.standard.string(forKey: "llmModel") ?? "anthropic/claude-sonnet-4"
        let provider = LLMProviderType(rawValue: providerRaw) ?? .openRouter
        let baseURL = provider.baseURL
        let apiKey = APIKeyStore.key(for: provider)

        logTask("provider=\(providerRaw) model=\(model) baseURL=\(baseURL) keyLen=\(apiKey.count)")

        guard !apiKey.isEmpty else {
            summarizeError = "No API key configured"
            isSummarizing = false
            logTask("ERROR: no API key")
            return
        }

        // Build the request
        guard let url = URL(string: baseURL) else {
            summarizeError = "Invalid URL"
            isSummarizing = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if provider == .anthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        logTask("sending HTTP request...")

        // Use URLSession directly — no actors involved
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    logTask("HTTP error: \(error)")
                    summarizeError = error.localizedDescription
                    isSummarizing = false
                    return
                }

                guard let data = data else {
                    logTask("no data returned")
                    summarizeError = "No response data"
                    isSummarizing = false
                    return
                }

                let httpCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                logTask("HTTP \(httpCode), data size=\(data.count)")

                guard httpCode == 200 else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    logTask("API error: \(body)")
                    summarizeError = "API error (\(httpCode))"
                    isSummarizing = false
                    return
                }

                // Parse LLM response
                let llmContent: String
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if provider == .anthropic {
                        let content = json["content"] as? [[String: Any]]
                        llmContent = content?.first?["text"] as? String ?? ""
                    } else {
                        let choices = json["choices"] as? [[String: Any]]
                        let message = choices?.first?["message"] as? [String: Any]
                        llmContent = message?["content"] as? String ?? ""
                    }
                } else {
                    llmContent = ""
                }

                logTask("llm response: \(llmContent.prefix(300))")

                guard !llmContent.isEmpty else {
                    summarizeError = "Empty response from AI"
                    isSummarizing = false
                    return
                }

                // Parse title + description from JSON response
                var title = ""
                var description = ""

                // Extract JSON from response (may be wrapped in ```json blocks)
                var jsonStr = llmContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if let start = jsonStr.range(of: "{"), let end = jsonStr.range(of: "}", options: .backwards) {
                    jsonStr = String(jsonStr[start.lowerBound...end.lowerBound])
                }
                if let jsonData = jsonStr.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    title = parsed["title"] as? String ?? ""
                    description = parsed["description"] as? String ?? ""
                    logTask("parsed title=\(title), desc length=\(description.count)")
                } else {
                    // Fallback: use whole response as title
                    title = llmContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    logTask("JSON parse failed, using raw as title")
                }

                // Update through binding
                self.task.title = title
                self.task.description = description
                self.task.rawInput = text
                logTask("set title=\(title)")

                // Also persist
                self.meetingManager.updateTask(self.task)
                logTask("persisted via updateTask")

                self.inputText = ""
                self.isSummarizing = false
                self.showAISummarize = false
                logTask("done")
            }
        }.resume()
    }

    private func debouncedSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem {
            Task { @MainActor in meetingManager.updateTask(task) }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveImmediately() {
        saveWork?.cancel()
        meetingManager.updateTask(task)
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let nsImage = image as? NSImage else { return }
                    ocrImage(nsImage)
                }
            } else if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let nsImage = NSImage(contentsOf: url) else { return }
                    ocrImage(nsImage)
                }
            }
        }
    }

    private func ocrImage(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            DispatchQueue.main.async {
                self.inputText = text
                self.pastedImage = nil
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
    }

    private func pasteImageFromClipboard() {
        let pb = NSPasteboard.general
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]
        for imageType in imageTypes {
            if let data = pb.data(forType: imageType), let image = NSImage(data: data) {
                pastedImage = image
                ocrImage(image)
                return
            }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: ["public.image"]
        ]) as? [URL], let url = urls.first, let image = NSImage(contentsOf: url) {
            pastedImage = image
            ocrImage(image)
            return
        }
        summarizeError = "No image found on clipboard"
    }

    private func handlePastedItems(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let nsImage = image as? NSImage else { return }
                    DispatchQueue.main.async {
                        self.pastedImage = nsImage
                        self.ocrImage(nsImage)
                    }
                }
                return
            }
        }
    }
}
