import SwiftUI
import UserNotifications

struct SettingsView: View {
    @State private var selectedTab: SettingsTab
    @State private var hasChanges = false

    enum SettingsTab: String, CaseIterable, Identifiable {
        case account = "Account"
        case general = "General"
        case ai = "AI"
        case markdown = "Markdown"
        case importData = "Import"
        case privacy = "Privacy"
        case t5t = "T5T"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .account: return "person.circle"
            case .general: return "gear"
            case .ai: return "brain"
            case .markdown: return "doc.text"
            case .importData: return "square.and.arrow.down"
            case .privacy: return "lock.shield"
            case .t5t: return "list.bullet.rectangle"
            }
        }
    }

    init(initialTab: SettingsTab = .account) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar
            VStack(alignment: .leading, spacing: 2) {
                Text("SETTINGS")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13))
                                .foregroundStyle(selectedTab == tab ? .white : .secondary)
                                .frame(width: 20)
                            Text(tab.rawValue)
                                .font(.system(size: 13))
                                .foregroundStyle(selectedTab == tab ? .white : .primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.8)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }

                Spacer()
            }
            .frame(width: 160)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))

            Divider()

            // Right content
            VStack(spacing: 0) {
                // Content
                Group {
                    switch selectedTab {
                    case .account: AccountSettingsView()
                    case .general: GeneralSettingsView()
                    case .ai: AISettingsView()
                    case .markdown: MarkdownSettingsView()
                    case .importData: ImportSettingsView()
                    case .privacy: PrivacySettingsView()
                    case .t5t: T5TSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 680, height: 520)
    }
}

// MARK: - Account Settings

struct AccountSettingsView: View {
    private var userName: String { UserDefaults.standard.string(forKey: "google_user_name") ?? "" }
    private var userEmail: String { UserDefaults.standard.string(forKey: "google_user_email") ?? "" }
    private var isSignedIn: Bool { KeychainHelper.load(key: "google_access_token") != nil }

    var body: some View {
        Form {
            Section("Google Account") {
                if isSignedIn && !userEmail.isEmpty {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "333333"))
                                .frame(width: 40, height: 40)
                            Text(initials)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(userName)
                                .font(.system(size: 14, weight: .medium))
                            Text(userEmail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    Button("Sign Out", role: .destructive) {
                        KeychainHelper.delete(key: "google_access_token")
                        KeychainHelper.delete(key: "google_refresh_token")
                        UserDefaults.standard.removeObject(forKey: "google_user_name")
                        UserDefaults.standard.removeObject(forKey: "google_user_email")
                        UserDefaults.standard.removeObject(forKey: "google_user_photo")
                        UserDefaults.standard.removeObject(forKey: "skippedAuth")
                    }
                } else {
                    Text("Not signed in")
                        .foregroundStyle(.secondary)
                    Text("Sign in from the main app window to connect your Google account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var initials: String {
        let parts = userName.split(separator: " ")
        let first = parts.first?.prefix(1) ?? ""
        let last = parts.count > 1 ? parts.last!.prefix(1) : ""
        return "\(first)\(last)".uppercased()
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("autoDetectMeetings") private var autoDetect = false
    @AppStorage("autoDetectionEngine") private var autoDetectionEngineRaw = AutoDetectionEngine.teamsV5.rawValue
    @AppStorage("autoStopSilenceDuration") private var autoStopDuration = 60.0
    @AppStorage("globalShortcutEnabled") private var globalShortcutEnabled = true
    @StateObject private var testCapture = RecordingDiagnosticsTestCapture()

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch NoteAI at login", isOn: $launchAtLogin)
            }

            Section("Auto-Detection") {
                Toggle("Automatically detect and record meetings", isOn: $autoDetect)

                Picker("Detection engine", selection: $autoDetectionEngineRaw) {
                    ForEach(AutoDetectionEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine.rawValue)
                    }
                }
                .disabled(!autoDetect)

                Text(autoDetectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Stop after silence:")
                    Slider(value: $autoStopDuration, in: 30...300, step: 15)
                    Text("\(Int(autoStopDuration))s")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }

            Section("Recording") {
                Toggle("Enable global shortcut (Cmd+Shift+R)", isOn: $globalShortcutEnabled)
            }

            Section("Notifications") {
                NotificationPermissionSetupView()
            }

            Section("Recording Diagnostics") {
                RecordingDiagnosticsSettingsView(snapshot: testCapture.snapshot)

                if let error = testCapture.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(hex: "FFA94D"))
                }

                HStack {
                    Button {
                        testCapture.isRunning ? testCapture.stop() : testCapture.start()
                    } label: {
                        Label(
                            testCapture.isRunning ? "Stop Test Capture" : "Run Test Capture",
                            systemImage: testCapture.isRunning ? "stop.fill" : "waveform"
                        )
                    }

                    Text(testCapture.isRunning ? "Listening for mic and system levels..." : "Runs a short local capture check without saving audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var autoDetectionDescription: String {
        let engine = AutoDetectionEngine(rawValue: autoDetectionEngineRaw) ?? .teamsV5
        switch engine {
        case .classicV4:
            return "When enabled, NoteAI uses the existing v4 detector for Teams, Google Meet, Chrome, Edge, Arc, and Safari activity."
        case .teamsV5:
            return "When enabled, NoteAI uses the v5 Teams detector. It combines Teams process, call-window, and audio evidence before starting recording. Accessibility permission improves call UI detection."
        }
    }
}

private struct NotificationPermissionSetupView: View {
    @State private var statusText = "Checking..."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Summary notifications")
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Request Notification Access") {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                    refresh()
                }
            }

            Text("NoteAI uses notifications for completed summaries and processing alerts. Recording works without this permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let label: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                label = "Allowed"
            case .denied:
                label = "Denied"
            case .notDetermined:
                label = "Not requested"
            @unknown default:
                label = "Unknown"
            }
            Task { @MainActor in
                statusText = label
            }
        }
    }
}

@MainActor
final class RecordingDiagnosticsTestCapture: ObservableObject {
    @Published var snapshot = RecordingDiagnosticsSnapshot.currentPermissions()
    @Published var isRunning = false
    @Published var errorMessage: String?

    private var manager: AudioCaptureManager?
    private var stopTask: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        let manager = AudioCaptureManager()
        manager.onDiagnosticsChange = { [weak self] snapshot in
            Task { @MainActor in
                self?.snapshot = snapshot
            }
        }
        manager.onAudioBuffer = { _ in }
        self.manager = manager
        isRunning = true

        Task {
            do {
                try await manager.startCapture()
                stopTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    await self?.stop()
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.isRunning = false
                self.manager = nil
            }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        manager?.stopCapture()
        manager = nil
        isRunning = false
        snapshot = RecordingDiagnosticsSnapshot.currentPermissions()
    }
}

private struct RecordingDiagnosticsSettingsView: View {
    let snapshot: RecordingDiagnosticsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RecordingDiagnosticsRow(
                title: "Microphone",
                icon: "mic.fill",
                diagnostic: snapshot.microphone
            )
            RecordingDiagnosticsRow(
                title: "System audio",
                icon: "speaker.wave.2.fill",
                diagnostic: snapshot.systemAudio
            )

            ForEach(snapshot.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color(hex: "FFA94D"))
            }
        }
    }
}

private struct RecordingDiagnosticsRow: View {
    let title: String
    let icon: String
    let diagnostic: RecordingSourceDiagnostic

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
            Text(title)
                .frame(width: 105, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(diagnostic.status.isCapturing ? Color.accentColor : Theme.textTertiary)
                        .frame(width: max(5, geometry.size.width * diagnostic.level.meterValue))
                }
            }
            .frame(height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
        .font(.system(size: 12))
    }

    private var statusText: String {
        switch diagnostic.status {
        case .idle:
            return "Idle"
        case .capturing:
            return "Capturing"
        case .unavailable:
            return "Unavailable"
        }
    }
}

// MARK: - AI Settings

struct AISettingsView: View {
    @AppStorage("llmProvider") private var providerRaw = "openrouter"
    @AppStorage("llmModel") private var selectedModelID = "anthropic/claude-sonnet-4"
    @AppStorage("whisperModel") private var whisperModel = "distil-large-v3"
    @AppStorage("meetingTemplate") private var templateRaw = "auto"

    // Per-provider API keys (Keychain-backed)
    @State private var openRouterKey = ""
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var nvidiaKey = ""

    @State private var remoteModels: [LLMModel] = []
    @State private var isFetchingModels = false
    @State private var modelSearchText = ""
    @State private var fetchError: String?

    private var provider: LLMProviderType {
        LLMProviderType(rawValue: providerRaw) ?? .openRouter
    }

    @AppStorage("ttsVoice") private var ttsVoice = "nova"
    @State private var ttsAPIKey = ""
    @State private var isPreviewingVoice = false
    @StateObject private var previewTTS = TextToSpeechService()

    var body: some View {
        Form {
            Section("Text-to-Speech") {
                HStack {
                    Picker("Voice", selection: $ttsVoice) {
                        ForEach(TextToSpeechService.voices, id: \.self) { voice in
                            Text(voice.capitalized).tag(voice)
                        }
                    }
                    Button {
                        previewVoice()
                    } label: {
                        if isPreviewingVoice {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 18))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(isPreviewingVoice)
                }
                SecureField("TTS API Key (optional)", text: $ttsAPIKey)
                    .onChange(of: ttsAPIKey) { _, newValue in
                        TextToSpeechService.saveTTSKey(newValue)
                    }
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text("Uses your NVIDIA API key by default. Or paste an OpenAI key here to use OpenAI directly.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // Transcription section
            Section("Transcription (On-Device)") {
                Picker("Whisper Model", selection: $whisperModel) {
                    Text("Tiny (fastest, ~30MB)").tag("tiny")
                    Text("Base (~140MB)").tag("base")
                    Text("Small (good accuracy, ~460MB)").tag("small")
                    Text("Distil Large v3 (fast + accurate, ~750MB)").tag("distil-large-v3")
                    Text("Large v3 (best accuracy, ~1.5GB)").tag("large-v3")
                }
            }

            // Meeting template
            Section("Meeting Format") {
                Picker("Template", selection: $templateRaw) {
                    ForEach(MeetingTemplate.allCases) { template in
                        Label(template.displayName, systemImage: template.icon).tag(template.rawValue)
                    }
                }

                Text(templateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Provider selection
            Section("Summarization Provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(LLMProviderType.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }
                .onChange(of: providerRaw) { _, newValue in
                    // Reset model to first available when switching providers
                    let p = LLMProviderType(rawValue: newValue) ?? .openRouter
                    let models = OpenRouterModels.models(for: p)
                    if let first = models.first {
                        selectedModelID = first.id
                    }
                    remoteModels = []
                }

                providerDescription
            }

            // API Key
            Section("API Key — \(provider.displayName)") {
                apiKeyField

                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                    Text(apiKeyHint)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if currentAPIKey.isEmpty {
                    Label(
                        "Required. Set here or via \(provider.envKeyName) env var.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            }

            // Model selection
            Section("Model") {
                modelSelectionView
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            loadKeysFromSecureStore()
            ttsAPIKey = TextToSpeechService.loadTTSKey()
        }
        .onChange(of: openRouterKey) { _, newValue in
            APIKeyStore.save(newValue, for: .openRouter)
        }
        .onChange(of: anthropicKey) { _, newValue in
            APIKeyStore.save(newValue, for: .anthropic)
        }
        .onChange(of: openAIKey) { _, newValue in
            APIKeyStore.save(newValue, for: .openAI)
        }
        .onChange(of: nvidiaKey) { _, newValue in
            APIKeyStore.save(newValue, for: .nvidia)
        }
    }

    // MARK: - Provider description

    @ViewBuilder
    private var providerDescription: some View {
        switch provider {
        case .openRouter:
            Text("Routes to 100+ models from Anthropic, OpenAI, Google, Meta, Mistral, DeepSeek, and more through a single API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .anthropic:
            Text("Direct connection to Anthropic's Claude models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .openAI:
            Text("Direct connection to OpenAI's GPT models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .nvidia:
            Text("NVIDIA Enterprise Inference Hub — access Claude Opus 4.6, Nemotron, Llama, and more via inference.nvidia.com.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - API key

    @ViewBuilder
    private var apiKeyField: some View {
        switch provider {
        case .openRouter:
            SecureField("OpenRouter API Key", text: $openRouterKey)
        case .anthropic:
            SecureField("Anthropic API Key", text: $anthropicKey)
        case .openAI:
            SecureField("OpenAI API Key", text: $openAIKey)
        case .nvidia:
            SecureField("NVIDIA API Key", text: $nvidiaKey)
        }
    }

    private var currentAPIKey: String {
        switch provider {
        case .openRouter: return openRouterKey
        case .anthropic: return anthropicKey
        case .openAI: return openAIKey
        case .nvidia: return nvidiaKey
        }
    }

    private var apiKeyHint: String {
        switch provider {
        case .openRouter: return "Get your key at openrouter.ai/keys"
        case .anthropic: return "Get your key at console.anthropic.com"
        case .openAI: return "Get your key at platform.openai.com/api-keys"
        case .nvidia: return "Get your key at inference.nvidia.com/key-management"
        }
    }

    // MARK: - Model selection

    @ViewBuilder
    private var modelSelectionView: some View {
        if provider == .openRouter {
            openRouterModelPicker
        } else {
            // Direct provider — show curated list
            Picker("Model", selection: $selectedModelID) {
                ForEach(OpenRouterModels.models(for: provider)) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        }
    }

    @ViewBuilder
    private var openRouterModelPicker: some View {
        // Curated popular models
        Picker("Model", selection: $selectedModelID) {
            Section("Popular Models") {
                ForEach(OpenRouterModels.popular) { model in
                    HStack {
                        Text(model.displayName)
                        Spacer()
                        if let cost = model.costPer1MInput {
                            Text("$\(cost, specifier: "%.2f")/1M in")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(model.id)
                }
            }

            if !filteredRemoteModels.isEmpty {
                Section("All Models") {
                    ForEach(filteredRemoteModels) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
            }
        }

        // Custom model ID field for any OpenRouter model
        HStack {
            TextField("Or enter model ID (e.g. anthropic/claude-opus-4)", text: $selectedModelID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }

        // Fetch full model list
        HStack {
            Button {
                Task { await fetchRemoteModels() }
            } label: {
                if isFetchingModels {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Browse All Models", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isFetchingModels)

            if !remoteModels.isEmpty {
                Text("\(remoteModels.count) models available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = fetchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        if !remoteModels.isEmpty {
            TextField("Search models...", text: $modelSearchText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var templateDescription: String {
        let template = MeetingTemplate(rawValue: templateRaw) ?? .auto
        switch template {
        case .auto: return "AI will detect the meeting type and adapt the summary format automatically."
        case .general: return "Standard format with decisions, action items, topics, and open questions."
        case .standup: return "Optimized for stand-ups: completed work, next tasks, and blockers per person."
        case .sales: return "Captures customer pain points, objections, commitments, and deal signals."
        case .oneOnOne: return "Focuses on feedback, career development, and personal action items."
        case .brainstorm: return "Captures all ideas proposed, directions chosen, and research tasks."
        }
    }

    private var filteredRemoteModels: [LLMModel] {
        if modelSearchText.isEmpty { return [] }
        return remoteModels.filter {
            $0.id.localizedCaseInsensitiveContains(modelSearchText) ||
            $0.name.localizedCaseInsensitiveContains(modelSearchText)
        }
        .prefix(50)
        .map { $0 }
    }

    private func fetchRemoteModels() async {
        isFetchingModels = true
        fetchError = nil
        do {
            remoteModels = try await OpenRouterModelFetcher.fetchModels()
        } catch {
            fetchError = "Failed to fetch: \(error.localizedDescription)"
        }
        isFetchingModels = false
    }

    private func loadKeysFromSecureStore() {
        openRouterKey = APIKeyStore.load(for: .openRouter)
        anthropicKey = APIKeyStore.load(for: .anthropic)
        openAIKey = APIKeyStore.load(for: .openAI)
        nvidiaKey = APIKeyStore.load(for: .nvidia)
    }

    private func previewVoice() {
        previewTTS.stop()
        isPreviewingVoice = true
        let sample = "Hi, I'm the \(ttsVoice) voice. This is how I sound when reading your notes and reports in NoteAI."
        previewTTS.speak(sample)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            isPreviewingVoice = false
        }
    }
}

// MARK: - Markdown Settings

struct MarkdownSettingsView: View {
    @AppStorage("markdownExportPath") private var exportPath = ""
    @AppStorage("autoExportMarkdown") private var autoExport = false
    @AppStorage("markdownFrontmatter") private var includeFrontmatter = true
    @AppStorage("markdownTimestamps") private var includeTimestamps = true

    var body: some View {
        Form {
            Section("Vault / Export Directory") {
                HStack {
                    TextField("Export path", text: $exportPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)

                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.message = "Choose a directory for Markdown export (e.g. your Obsidian vault)"
                        if panel.runModal() == .OK, let url = panel.url {
                            exportPath = url.path
                        }
                    }

                    if !exportPath.isEmpty {
                        Button {
                            exportPath = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Toggle("Auto-export after each meeting", isOn: $autoExport)

                if autoExport && exportPath.isEmpty {
                    Label("Set an export directory above to enable auto-export", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                Text("Meeting notes will be saved as individual .md files in this directory. Works great with Obsidian, iA Writer, or any Markdown-based notes app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Markdown Format") {
                Toggle("Include YAML frontmatter (tags, date, duration)", isOn: $includeFrontmatter)
                Toggle("Include timestamps in transcript", isOn: $includeTimestamps)
            }

            if !exportPath.isEmpty {
                Section("Quick Actions") {
                    Button("Open Export Directory") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: exportPath))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - T5T Settings

struct T5TSettingsView: View {
    @State private var config: T5TConfig = .empty
    private let store = MeetingStore()

    var body: some View {
        T5TConfigEditor(config: $config) { newConfig in
            try? store.saveT5TConfig(newConfig)
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            config = (try? store.loadT5TConfig()) ?? .empty
        }
    }
}

// MARK: - Privacy Settings

struct PrivacySettingsView: View {
    @AppStorage("retainAudio") private var retainAudio = false
    @AppStorage("audioRetentionDays") private var retentionDays = 7.0

    var body: some View {
        Form {
            Section("Audio Storage") {
                Toggle("Retain audio files after transcription", isOn: $retainAudio)

                if retainAudio {
                    HStack {
                        Text("Delete audio after:")
                        Slider(value: $retentionDays, in: 1...90, step: 1)
                        Text("\(Int(retentionDays)) days")
                            .monospacedDigit()
                            .frame(width: 60)
                    }
                }
            }

            Section("Data") {
                Button("Open Data Directory") {
                    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    let dir = appSupport.appendingPathComponent("NoteAI")
                    NSWorkspace.shared.open(dir)
                }

                Button("Delete All Data", role: .destructive) {
                    // Will show confirmation in production
                }
            }

            Section("Information") {
                Text("NoteAI processes all audio on-device by default. Audio data never leaves your Mac unless you explicitly enable cloud transcription or summarization.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Import Settings

struct ImportSettingsView: View {
    @EnvironmentObject private var manager: MeetingManager
    @State private var importPath = ""
    @State private var isImporting = false
    @State private var importResult: NotionImporter.ImportResult?
    @State private var importError: String?

    var body: some View {
        Form {
            Section("Import from Notion") {
                Text("Export your Notion workspace as **Markdown & CSV**, unzip the download, then select the exported folder below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Notion export folder", text: $importPath)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)

                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.message = "Select your unzipped Notion export folder"
                        if panel.runModal() == .OK, let url = panel.url {
                            importPath = url.path
                        }
                    }
                }

                Button {
                    performImport()
                } label: {
                    if isImporting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing...")
                        }
                    } else {
                        Label("Import Notes", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(importPath.isEmpty || isImporting)
            }

            if let result = importResult {
                Section("Import Results") {
                    Label("\(result.imported.count) notes imported", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)

                    if !result.skipped.isEmpty {
                        Label("\(result.skipped.count) files skipped", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        ForEach(result.skipped, id: \.self) { name in
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("\(result.totalFilesFound) Markdown files found in directory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = importError {
                Section("Error") {
                    Label(error, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("How to Export from Notion") {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Open Notion and go to **Settings & members**")
                    step(2, "Click **Settings** in the sidebar")
                    step(3, "Scroll to **Export all workspace content**")
                    step(4, "Choose **Markdown & CSV** format")
                    step(5, "Download and unzip the file")
                    step(6, "Select the unzipped folder above")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func performImport() {
        isImporting = true
        importResult = nil
        importError = nil

        let url = URL(fileURLWithPath: importPath)
        do {
            let result = try manager.importNotesFromNotion(directoryURL: url)
            importResult = result
        } catch {
            importError = error.localizedDescription
        }
        isImporting = false
    }
}
