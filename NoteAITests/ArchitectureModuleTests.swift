import XCTest
import SwiftUI
@testable import NoteAI

final class ArchitectureModuleTests: XCTestCase {
    func testV5AutoDetectionDefaultsArmTeamsSmartWhenNoEngineWasChosen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NoteAI.v5.auto-detect.default.\(UUID().uuidString)"))

        XCTAssertNil(defaults.object(forKey: AutoDetectionDefaults.engineKey))
        XCTAssertFalse(defaults.bool(forKey: AutoDetectionDefaults.autoDetectKey))

        AutoDetectionDefaults.migrateToV5DefaultsIfNeeded(defaults)

        XCTAssertTrue(defaults.bool(forKey: AutoDetectionDefaults.autoDetectKey))
        XCTAssertEqual(defaults.string(forKey: AutoDetectionDefaults.engineKey), AutoDetectionEngine.teamsV5.rawValue)
    }

    func testV5AutoDetectionMigrationPreservesExplicitEngineChoice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NoteAI.v5.auto-detect.explicit.\(UUID().uuidString)"))
        defaults.set(false, forKey: AutoDetectionDefaults.autoDetectKey)
        defaults.set(AutoDetectionEngine.classicV4.rawValue, forKey: AutoDetectionDefaults.engineKey)

        AutoDetectionDefaults.migrateToV5DefaultsIfNeeded(defaults)

        XCTAssertFalse(defaults.bool(forKey: AutoDetectionDefaults.autoDetectKey))
        XCTAssertEqual(defaults.string(forKey: AutoDetectionDefaults.engineKey), AutoDetectionEngine.classicV4.rawValue)
    }

    func testSidebarBrandShowsOnlyCenteredLogo() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/MeetingLibrary/MeetingLibraryView.swift"))
        let brandHeaderStart = try XCTUnwrap(source.range(of: "private func brandHeader(layout: CommandCenterLayout) -> some View"))
        let nextFunction = try XCTUnwrap(source.range(of: "private func searchAndFilters", range: brandHeaderStart.upperBound..<source.endIndex))
        let brandHeaderSource = String(source[brandHeaderStart.lowerBound..<nextFunction.lowerBound])

        XCTAssertTrue(brandHeaderSource.contains("Image(systemName: \"brain.head.profile\")"))
        XCTAssertFalse(brandHeaderSource.contains("Text(\"NoteAI\")"))
        XCTAssertFalse(brandHeaderSource.contains("Text(\"v5.0\")"))
        XCTAssertFalse(brandHeaderSource.contains("VStack(alignment: .leading"))
        XCTAssertTrue(brandHeaderSource.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)"))
        XCTAssertTrue(brandHeaderSource.contains(".frame(height: layout.sidebarBrandHeaderHeight, alignment: .center)"))
    }

    func testNVIDIAModelCatalogIncludesOpus47BeforeOpus46() throws {
        let models = OpenRouterModels.models(for: .nvidia)

        let opus47Index = try XCTUnwrap(models.firstIndex { $0.id == "aws/anthropic/bedrock-claude-opus-4-7" })
        let opus46Index = try XCTUnwrap(models.firstIndex { $0.id == "azure/anthropic/claude-opus-4-6" })

        XCTAssertEqual(models[opus47Index].name, "Claude Opus 4.7")
        XCTAssertEqual(models[opus47Index].contextWindow, 1_000_000)
        XCTAssertLessThan(opus47Index, opus46Index)
    }

    func testTextAISelectionDefaultsToSelectableNVIDIAGPT61Sol() throws {
        let suite = "NoteAI.llm-selection.default.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let selection = LLMSelection.current(defaults: defaults)
        let model = try XCTUnwrap(OpenRouterModels.models(for: selection.provider)
            .first { $0.id == selection.modelID })

        XCTAssertEqual(selection.provider, .nvidia)
        XCTAssertEqual(selection.modelID, "azure/openai/gpt-6.1-sol")
        XCTAssertEqual(model.displayName, "GPT-6.1 Sol")
        XCTAssertEqual(OpenRouterModels.models(for: .nvidia).first?.id, selection.modelID)
        XCTAssertNil(defaults.object(forKey: "llmProvider"))
        XCTAssertNil(defaults.object(forKey: "llmModel"))
    }

    func testTextAISelectionPreservesSavedCustomProviderModel() throws {
        let suite = "NoteAI.llm-selection.saved.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("openrouter", forKey: "llmProvider")
        defaults.set("custom/my-selected-model", forKey: "llmModel")

        let selection = LLMSelection.current(defaults: defaults)

        XCTAssertEqual(selection.provider, .openRouter)
        XCTAssertEqual(selection.modelID, "custom/my-selected-model")
    }

    func testTextAISelectionPreservesLegacyModelWithoutSavedProvider() throws {
        let suite = "NoteAI.llm-selection.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("custom/legacy-openrouter-model", forKey: "llmModel")

        let selection = LLMSelection.current(defaults: defaults)

        XCTAssertEqual(selection.provider, .openRouter)
        XCTAssertEqual(selection.modelID, "custom/legacy-openrouter-model")
        XCTAssertNil(defaults.object(forKey: "llmProvider"))
    }

    func testTextAISelectionUsesChosenProvidersModelWhenSavedModelIsBlank() throws {
        let suite = "NoteAI.llm-selection.blank.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("anthropic", forKey: "llmProvider")
        defaults.set(" \n ", forKey: "llmModel")

        let selection = LLMSelection.current(defaults: defaults)

        XCTAssertEqual(selection.provider, .anthropic)
        XCTAssertEqual(selection.modelID, "claude-sonnet-4-20250514")
    }

    func testTextAISelectionReadsPreferenceChangesForNextRequest() throws {
        let suite = "NoteAI.llm-selection.changes.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(LLMSelection.current(defaults: defaults).modelID, "azure/openai/gpt-6.1-sol")
        defaults.set("openai", forKey: "llmProvider")
        defaults.set("gpt-4o", forKey: "llmModel")

        let changed = LLMSelection.current(defaults: defaults)
        XCTAssertEqual(changed.provider, .openAI)
        XCTAssertEqual(changed.modelID, "gpt-4o")
    }

    func testProcessTapProviderTranslatesPIDToCoreAudioProcessObjectID() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/Audio/ProcessTapProvider.swift"))

        XCTAssertTrue(source.contains("kAudioHardwarePropertyTranslatePIDToProcessObject"))
        XCTAssertFalse(source.contains("AudioObjectID(bitPattern: processID)"))
    }

    func testAudioConverterCacheKeyIncludesFullInputFormatForBluetoothRouteChanges() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/Audio/AudioCaptureManager.swift"))

        XCTAssertTrue(source.contains("struct AudioConverterCacheKey: Hashable"))
        XCTAssertTrue(source.contains("let channelCount: AVAudioChannelCount"))
        XCTAssertTrue(source.contains("let commonFormat: AVAudioCommonFormat"))
        XCTAssertTrue(source.contains("let interleaved: Bool"))
        XCTAssertTrue(source.contains("converterCache[cacheKey]"))
        XCTAssertFalse(source.contains("converterCache[srcFormat.sampleRate]"))
    }

    func testAudioCaptureCoalescesOnlyLevelPublicationAndKeepsAudioDeliverySynchronous() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/Audio/AudioCaptureManager.swift"))
        let appAudioHandler = try sourceFragment(
            named: "private func handleAppAudioBuffer(_ buffer: AVAudioPCMBuffer)",
            before: "    private func handleMicBuffer",
            in: source
        )
        let microphoneHandler = try sourceFragment(
            named: "private func handleMicBuffer(_ buffer: AVAudioPCMBuffer)",
            before: "    /// Resample any audio buffer",
            in: source
        )

        for (handler, ringName, sourceName) in [
            (appAudioHandler, "appAudioRing", "systemAudio"),
            (microphoneHandler, "micAudioRing", "microphone"),
        ] {
            XCTAssertTrue(handler.contains("updateDiagnostics(publication: .coalesced)"))
            XCTAssertTrue(handler.contains("\(ringName).append(resampled)"))
            XCTAssertTrue(handler.contains("\(ringName).mergeIfReady(targetDuration: 7.0)"))
            XCTAssertTrue(handler.contains("onAudioBuffer?(CapturedAudioBuffer(source: .\(sourceName), buffer: merged))"))
            XCTAssertFalse(handler.contains("asyncAfter"))
            XCTAssertFalse(handler.contains("Task {"))
        }
    }

    func testLiveTranscriptUsesLazyRowsAndNonAnimatedBottomScrolling() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/TranscriptViewer/TranscriptView.swift"))
        let transcriptArea = try sourceFragment(
            named: "private var transcriptArea: some View",
            before: "    private var resizeHandle: some View",
            in: source
        )

        XCTAssertTrue(transcriptArea.contains("ScrollView {\n                LazyVStack(alignment: .leading, spacing: 6)"))
        XCTAssertTrue(transcriptArea.contains("ForEach(segments)"))
        XCTAssertTrue(transcriptArea.contains(".id(segment.id)"))
        XCTAssertTrue(transcriptArea.contains(".textSelection(.enabled)"))
        XCTAssertEqual(
            transcriptArea.components(separatedBy: "proxy.scrollTo(last.id, anchor: .bottom)").count - 1,
            2
        )
        XCTAssertEqual(transcriptArea.components(separatedBy: "withAnimation").count - 1, 1)
        XCTAssertTrue(transcriptArea.contains("proxy.scrollTo(request.segmentID, anchor: .center)"))
    }

    func testMicrophoneCaptureAvoidsVoiceProcessingDucking() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/Audio/MicrophoneCaptureManager.swift"))

        XCTAssertFalse(source.contains("setVoiceProcessingEnabled(true)"))
        XCTAssertFalse(source.contains("voiceProcessingOtherAudioDuckingConfiguration"))
        XCTAssertTrue(source.contains("Raw microphone capture avoids AVAudioEngine voice-processing ducking"))
        XCTAssertTrue(source.contains("let format = inputNode.outputFormat(forBus: 0)"))
    }

    func testMeetingNamePromptIncludesDestructiveDiscardAction() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/MeetingLibrary/MeetingNamePromptView.swift"))

        XCTAssertTrue(source.contains("var onDiscard: () -> Void"))
        XCTAssertTrue(source.contains("Button(role: .destructive)"))
        XCTAssertTrue(source.contains("Text(\"Discard\")"))
        XCTAssertTrue(source.contains("onDiscard()"))
        XCTAssertTrue(source.contains("Button(\"Use Default\")"))
        XCTAssertTrue(source.contains("Button(\"Save & Process\")"))
    }

    func testMeetingLibraryPromptWiresDiscardWithoutProcessing() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/MeetingLibrary/MeetingLibraryView.swift"))

        XCTAssertTrue(source.contains("onDiscard: {"))
        XCTAssertTrue(source.contains("meetingManager.discardPendingRecording()"))
    }

    func testTopBarRecordingControlOpensLiveTranscriptWhileRecording() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/MeetingLibrary/MeetingLibraryView.swift"))
        let methodSource = try sourceFragment(
            named: "private func topBarRecordingControl(layout: CommandCenterLayout) -> some View",
            before: "    // MARK: - Sidebar",
            in: source
        )

        XCTAssertTrue(methodSource.contains("selection = nil"))
        XCTAssertTrue(methodSource.contains(".accessibilityAddTraits(.isButton)"))
        XCTAssertTrue(methodSource.contains(".help(\"Show live transcription\")"))
    }

    func testTopBarRecordingControlUsesMeetingWaveformIcon() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/MeetingLibrary/MeetingLibraryView.swift"))
        let methodSource = try sourceFragment(
            named: "private func topBarRecordingControl(layout: CommandCenterLayout) -> some View",
            before: "    // MARK: - Sidebar",
            in: source
        )

        XCTAssertTrue(methodSource.contains("LibraryListPresentation.SidebarItemKind.meeting.icon"))
        XCTAssertTrue(methodSource.contains("LibraryListPresentation.SidebarItemKind.meeting.tint"))
        XCTAssertFalse(methodSource.contains("Image(systemName: readiness.systemImage)"))
    }

    func testMeetingManagerDiscardPendingRecordingClearsTransientRecordingState() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/App/MeetingManager.swift"))
        let methodStart = try XCTUnwrap(source.range(of: "func discardPendingRecording()"))
        let nextMethod = try XCTUnwrap(source.range(of: "func toggleActionItem", range: methodStart.upperBound..<source.endIndex))
        let methodSource = String(source[methodStart.lowerBound..<nextMethod.lowerBound])

        XCTAssertTrue(methodSource.contains("showMeetingNamePrompt = false"))
        XCTAssertTrue(methodSource.contains("pendingMeetingName = \"\""))
        XCTAssertTrue(methodSource.contains("currentTranscript = []"))
        XCTAssertTrue(methodSource.contains("speakerAttribution = TranscriptSpeakerAttribution()"))
        XCTAssertTrue(methodSource.contains("currentMeetingStart = nil"))
        XCTAssertTrue(methodSource.contains("currentDetectedAppName = nil"))
        XCTAssertTrue(methodSource.contains("currentPreferredCaptureSource = nil"))
        XCTAssertTrue(methodSource.contains("recordingDuration = 0"))
        XCTAssertTrue(methodSource.contains("summarizationStatus = .idle"))
        XCTAssertTrue(methodSource.contains("state = .idle"))
        XCTAssertFalse(methodSource.contains("summarizationEngine.summarize"))
        XCTAssertFalse(methodSource.contains("meetingStore.save"))
    }

    func testLibraryOperationsFilterMatchesMeetingTitleAndTranscript() {
        let meeting = Meeting(
            id: UUID(),
            title: "Roadmap Sync",
            date: Date(),
            duration: 120,
            transcript: [TranscriptSegment(text: "Discussed Grace roadmap")],
            summary: MeetingSummary(decisions: ["Ship preview"], topics: ["Inference"])
        )
        let otherMeeting = Meeting(
            id: UUID(),
            title: "Planning",
            date: Date(),
            duration: 60,
            transcript: [],
            summary: MeetingSummary()
        )

        XCTAssertEqual(LibraryOperations.filter(meetings: [meeting, otherMeeting], query: "grace").map(\.id), [meeting.id])
        XCTAssertEqual(LibraryOperations.filter(meetings: [meeting, otherMeeting], query: "ROADMAP").map(\.id), [meeting.id])
        XCTAssertEqual(LibraryOperations.filter(meetings: [meeting, otherMeeting], query: "").count, 2)
        XCTAssertTrue(LibraryOperations.filter(meetings: [meeting, otherMeeting], query: "missing").isEmpty)
    }

    func testMeetingCaptureWorkflowFormatsTranscriptAndFallbackSummary() {
        let segments = [
            TranscriptSegment(id: 1, text: "Hello there", startTime: 3, speaker: "Alice", confidence: 0.9),
            TranscriptSegment(id: 2, text: "Follow up next week", startTime: 65, speaker: nil, confidence: 0.9),
        ]

        let text = MeetingCaptureWorkflow.transcriptText(from: segments)
        let fallback = MeetingCaptureWorkflow.failedSummary(errorDescription: "No key")

        XCTAssertTrue(text.contains("[00:03] Alice: Hello there"))
        XCTAssertTrue(text.contains("[01:05] Speaker 1: Follow up next week"))
        XCTAssertEqual(fallback.topics, ["Summarization failed: No key"])
        XCTAssertFalse(fallback.wasSummarized)
    }

    func testMeetingCaptureWorkflowDoesNotBlameSettingsForMalformedModelOutput() {
        let fallback = MeetingCaptureWorkflow.failedSummary(
            errorDescription: "The data couldn't be read because it isn't in the correct format."
        )

        XCTAssertEqual(
            fallback.openQuestions,
            ["Use Regenerate summary to try again. If the problem continues, select another model in Settings > AI."]
        )
    }

    func testMeetingCaptureWorkflowUsesRetryGuidanceForTypedParseFailure() {
        let fallback = MeetingCaptureWorkflow.failedSummary(error: SummarizationError.parseError)

        XCTAssertEqual(
            fallback.openQuestions,
            ["Use Regenerate summary to try again. If the problem continues, select another model in Settings > AI."]
        )
    }

    func testMeetingCaptureWorkflowIncludesSpeakerContextForSummaries() {
        let segments = [
            TranscriptSegment(id: 1, text: "We should prioritize the beta.", startTime: 3, speaker: "speaker-remote", confidence: 0.9)
        ]
        let profiles = [
            "speaker-remote": SpeakerProfile(
                speakerID: "speaker-remote",
                name: "Sarah Chen",
                role: "VP of Product",
                company: "Acme",
                notes: "Decision maker for the beta plan."
            )
        ]

        let input = MeetingCaptureWorkflow.summaryInput(
            from: segments,
            speakerLabels: [:],
            speakerProfiles: profiles
        )

        XCTAssertTrue(input.contains("SPEAKER CONTEXT"))
        XCTAssertTrue(input.contains("Sarah Chen — VP of Product, Acme. Decision maker for the beta plan."))
        XCTAssertTrue(input.contains("[00:03] Sarah Chen: We should prioritize the beta."))
    }

    func testTranscriptImportParserReadsTeamsStyleSpeakerBlocks() {
        let raw = """
        Sarah Chen
        0:01
        We should review the deployment plan before Friday.

        JP Santana 0:08
        I will summarize the risks and send the next steps.
        """

        let segments = TranscriptImportParser.parse(raw)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speaker, "Sarah Chen")
        XCTAssertEqual(segments[0].startTime, 1, accuracy: 0.01)
        XCTAssertEqual(segments[0].text, "We should review the deployment plan before Friday.")
        XCTAssertEqual(segments[1].speaker, "JP Santana")
        XCTAssertEqual(segments[1].startTime, 8, accuracy: 0.01)
        XCTAssertEqual(segments[1].text, "I will summarize the risks and send the next steps.")
    }

    func testTranscriptImportParserPreservesTextWithoutSpeakerOrTimestamp() {
        let raw = """
        This is pasted text without Teams speaker metadata.
        It should still become a useful transcript segment.
        """

        let segments = TranscriptImportParser.parse(raw)

        XCTAssertEqual(segments.count, 1)
        XCTAssertNil(segments[0].speaker)
        XCTAssertEqual(segments[0].startTime, 0, accuracy: 0.01)
        XCTAssertEqual(
            segments[0].text,
            "This is pasted text without Teams speaker metadata. It should still become a useful transcript segment."
        )
    }

    func testV6UsesSeparateLocalNamespace() {
        XCTAssertTrue(AppEnvironment.isV6(bundleIdentifier: "com.noteai.app.v6", displayName: "NoteAI v6"))
        XCTAssertEqual(
            AppEnvironment.storageNamespace(bundleIdentifier: "com.noteai.app.v6", displayName: "NoteAI v6"),
            "NoteAI-v6"
        )
        XCTAssertEqual(
            AppEnvironment.storageNamespace(bundleIdentifier: "com.noteai.app", displayName: "NoteAI"),
            "NoteAI"
        )
    }

    func testAppEnvironmentBuildsAboutVersionInfoFromBundleMetadata() {
        let info = AppEnvironment.versionInfo(
            displayName: "NoteAI v6",
            marketingVersion: "6.0",
            buildNumber: "42",
            bundleIdentifier: "com.noteai.app.v6"
        )

        XCTAssertEqual(info.displayName, "NoteAI v6")
        XCTAssertEqual(info.version, "6.0")
        XCTAssertEqual(info.build, "42")
        XCTAssertEqual(info.bundleIdentifier, "com.noteai.app.v6")
        XCTAssertEqual(info.versionSummary, "Version 6.0 (42)")
    }

    func testFocusedPrimaryTargetPublishesV7AndKeepsV6Identity() throws {
        let projectSource = try String(contentsOf: repositoryRoot().appendingPathComponent("project.yml"))
        let primarySource = try sourceFragment(named: "  NoteAI:\n", before: "  NoteAIv6:\n", in: projectSource)

        XCTAssertTrue(primarySource.contains("PRODUCT_BUNDLE_IDENTIFIER: com.noteai.app"))
        XCTAssertTrue(primarySource.contains("MARKETING_VERSION: \"7.0\""))
        XCTAssertTrue(projectSource.contains("PRODUCT_BUNDLE_IDENTIFIER: com.noteai.app.v6"))
        XCTAssertEqual(projectSource.components(separatedBy: "MARKETING_VERSION: \"6.0\"").count - 1, 1)
    }

    func testSettingsExposeAboutPanelWithRuntimeVersionMetadata() throws {
        let source = try settingsSource()

        XCTAssertTrue(source.contains("case about = \"About\""))
        XCTAssertTrue(source.contains("AboutSettingsView"))
        XCTAssertTrue(source.contains("AppEnvironment.versionInfo()"))
        XCTAssertTrue(source.contains("Bundle Identifier"))
        XCTAssertTrue(source.contains("Build"))
    }

    func testMeetingCaptureWorkflowPreservesImportedTranscriptEvidence() {
        let evidence = EvidenceSource(kind: .teamsTranscriptPaste, title: "Teams Transcript", externalID: nil)
        let meeting = MeetingCaptureWorkflow.makeMeeting(
            title: "Imported Call",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            transcript: [TranscriptSegment(text: "Discussed the customer plan.")],
            summary: MeetingSummary(topics: ["Customer plan"], wasSummarized: true),
            sourceEvidence: evidence
        )

        XCTAssertEqual(meeting.sourceEvidence?.kind, .teamsTranscriptPaste)
        XCTAssertEqual(meeting.sourceEvidence?.title, "Teams Transcript")
        XCTAssertEqual(meeting.transcript.first?.text, "Discussed the customer plan.")
    }

    func testRecordingReadinessFallsBackToManualWhenCalendarAndDetectionAreMissing() {
        let readiness = MeetingRecordingReadiness.resolve(
            recordingState: .idle,
            autoDetectEnabled: true,
            detectionState: .monitoring,
            detectedApp: nil,
            calendarAuthorization: .denied,
            upcomingCalendarEvent: nil
        )

        XCTAssertEqual(readiness.mode, .manualFallback)
        XCTAssertEqual(readiness.title, "Manual recording")
        XCTAssertTrue(readiness.detail.contains("Calendar access is unavailable"))
        XCTAssertEqual(readiness.primaryActionTitle, "Start Recording")
    }

    func testRecordingReadinessSurfacesLikelyMeetingAppSignal() {
        let readiness = MeetingRecordingReadiness.resolve(
            recordingState: .idle,
            autoDetectEnabled: true,
            detectionState: .monitoring,
            detectedApp: "Microsoft Teams",
            calendarAuthorization: .notDetermined,
            upcomingCalendarEvent: nil
        )

        XCTAssertEqual(readiness.mode, .likelyMeeting)
        XCTAssertEqual(readiness.title, "Microsoft Teams detected")
        XCTAssertTrue(readiness.detail.contains("likely meeting signal"))
        XCTAssertEqual(readiness.badgeTitle, "Signal")
    }

    func testRecordingReadinessAutoArmsForUpcomingCalendarEvent() {
        let event = CalendarMeetingSignal(
            title: "Customer Sync",
            startDate: Date(timeIntervalSince1970: 1_000),
            endDate: Date(timeIntervalSince1970: 2_000)
        )

        let readiness = MeetingRecordingReadiness.resolve(
            recordingState: .idle,
            autoDetectEnabled: true,
            detectionState: .monitoring,
            detectedApp: nil,
            calendarAuthorization: .authorized,
            upcomingCalendarEvent: event
        )

        XCTAssertEqual(readiness.mode, .calendarArmed)
        XCTAssertEqual(readiness.title, "Customer Sync soon")
        XCTAssertTrue(readiness.detail.contains("auto-armed"))
        XCTAssertEqual(readiness.badgeTitle, "Armed")
    }

    func testMeetingSpeakerSuggestionsNormalizeAndDeduplicateCalendarAttendees() {
        let suggestions = MeetingSpeakerSuggestion.deduplicated([
            MeetingSpeakerSuggestion(name: " Sarah Chen ", email: " Sarah.Chen@Acme.COM "),
            MeetingSpeakerSuggestion(name: "Sarah Chen", email: "sarah.chen@acme.com"),
            MeetingSpeakerSuggestion(name: "JP Santana", email: "jp@example.com"),
            MeetingSpeakerSuggestion(name: "", email: "empty@example.com"),
        ])

        XCTAssertEqual(suggestions.map(\.displayName), ["Sarah Chen", "JP Santana"])
        XCTAssertEqual(suggestions.first?.email, "sarah.chen@acme.com")
        XCTAssertEqual(suggestions.first?.subtitle, "sarah.chen@acme.com")
    }

    func testMeetingSpeakerSuggestionCreatesSpeakerProfileWithoutPersistingCalendarEmailAsName() throws {
        let suggestion = try XCTUnwrap(MeetingSpeakerSuggestion(name: "Sarah Chen", email: "sarah.chen@acme.com"))
        let profile = suggestion.profile(for: "speaker-remote")

        XCTAssertEqual(profile.speakerID, "speaker-remote")
        XCTAssertEqual(profile.name, "Sarah Chen")
        XCTAssertNil(profile.role)
        XCTAssertNil(profile.company)
        XCTAssertEqual(profile.notes, "Calendar attendee: sarah.chen@acme.com")
    }

    func testSpeakerLabelingResolvesStablePlaceholdersAndOverrides() {
        var meeting = Meeting(
            id: UUID(),
            title: "Speaker Sync",
            date: Date(timeIntervalSince1970: 0),
            duration: 120,
            transcript: [
                TranscriptSegment(id: 1, text: "Fallback speaker.", startTime: 0, speaker: nil, confidence: 0.9),
                TranscriptSegment(id: 2, text: "Known placeholder.", startTime: 5, speaker: "speaker-2", confidence: 0.9),
                TranscriptSegment(id: 3, text: "Named participant.", startTime: 10, speaker: "Ana", confidence: 0.9),
            ],
            summary: MeetingSummary()
        )

        XCTAssertEqual(meeting.speakerID(for: meeting.transcript[0]), "speaker-1")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[0]), "Speaker 1")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[1]), "Speaker 2")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[2]), "Ana")

        meeting.setSpeakerLabel(speakerID: "speaker-1", displayName: "JP")
        meeting.setSpeakerLabel(speakerID: "speaker-2", displayName: "Customer")

        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[0]), "JP")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[1]), "Customer")
    }

    func testMeetingCaptureWorkflowAssignsPlaceholderSpeakersBeforePersisting() {
        let meeting = MeetingCaptureWorkflow.makeMeeting(
            title: "Fallback Speakers",
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 30),
            transcript: [
                TranscriptSegment(id: 1, text: "We need a stable label.", startTime: 0, speaker: nil, confidence: 0.9)
            ],
            summary: MeetingSummary()
        )

        XCTAssertEqual(meeting.transcript.first?.speaker, "speaker-1")
        XCTAssertEqual(meeting.speakerDisplayName(for: meeting.transcript[0]), "Speaker 1")
    }

    func testAudioSourcePlaceholdersSeparateLocalAndRemoteWhenAvailable() {
        let localSegments = TranscriptSpeakerLabels.assignPlaceholders(
            to: [
                TranscriptSegment(id: 1, text: "Local voice.", startTime: 0, speaker: nil, confidence: 0.9)
            ],
            fallbackSpeakerID: CapturedAudioSource.microphone.fallbackSpeakerID
        )
        let remoteSegments = TranscriptSpeakerLabels.assignPlaceholders(
            to: [
                TranscriptSegment(id: 2, text: "Remote voice.", startTime: 7, speaker: nil, confidence: 0.9)
            ],
            fallbackSpeakerID: CapturedAudioSource.systemAudio.fallbackSpeakerID
        )

        XCTAssertEqual(localSegments[0].speaker, "speaker-local")
        XCTAssertEqual(remoteSegments[0].speaker, "speaker-remote")
        XCTAssertEqual(TranscriptSpeakerLabels.displayName(for: "speaker-local", labels: [:]), "You")
        XCTAssertEqual(TranscriptSpeakerLabels.displayName(for: "speaker-remote", labels: [:]), "Remote audio")
    }

    func testSpeakerAttributionAssignsStablePerRecordingRemoteSpeakerIDs() {
        var attribution = TranscriptSpeakerAttribution()

        let segments = [
            TranscriptSegment(id: 1, text: "Local voice.", startTime: 0, speaker: nil, confidence: 0.9),
            TranscriptSegment(id: 2, text: "First remote voice.", startTime: 4, speaker: nil, confidence: 0.9),
            TranscriptSegment(id: 3, text: "Second remote voice.", startTime: 8, speaker: nil, confidence: 0.9),
            TranscriptSegment(id: 4, text: "First remote again.", startTime: 12, speaker: nil, confidence: 0.9)
        ]

        let attributed = [
            attribution.attributedSegment(
                segments[0],
                source: .microphone,
                hint: SpeakerAttributionHint(rawSpeakerID: "local-user", confidence: 0.95)
            ),
            attribution.attributedSegment(
                segments[1],
                source: .systemAudio,
                hint: SpeakerAttributionHint(rawSpeakerID: "teams-user-a", confidence: 0.91)
            ),
            attribution.attributedSegment(
                segments[2],
                source: .systemAudio,
                hint: SpeakerAttributionHint(rawSpeakerID: "teams-user-b", confidence: 0.88)
            ),
            attribution.attributedSegment(
                segments[3],
                source: .systemAudio,
                hint: SpeakerAttributionHint(rawSpeakerID: "teams-user-a", confidence: 0.9)
            )
        ]

        XCTAssertEqual(attributed.map(\.speaker), [
            "speaker-local",
            "speaker-remote-1",
            "speaker-remote-2",
            "speaker-remote-1"
        ])
        XCTAssertEqual(TranscriptSpeakerLabels.displayName(for: "speaker-remote-1", labels: [:]), "Remote speaker 1")
        XCTAssertEqual(TranscriptSpeakerLabels.displayName(for: "speaker-remote-2", labels: [:]), "Remote speaker 2")
    }

    func testSpeakerAttributionFallsBackWhenRemoteHintIsMissingOrLowConfidence() {
        var attribution = TranscriptSpeakerAttribution()

        let missingHint = attribution.attributedSegment(
            TranscriptSegment(id: 1, text: "Remote voice.", startTime: 0, speaker: nil, confidence: 0.9),
            source: .systemAudio,
            hint: nil
        )
        let lowConfidence = attribution.attributedSegment(
            TranscriptSegment(id: 2, text: "Uncertain remote voice.", startTime: 7, speaker: nil, confidence: 0.9),
            source: .systemAudio,
            hint: SpeakerAttributionHint(rawSpeakerID: "teams-user-a", confidence: 0.44)
        )

        XCTAssertEqual(missingHint.speaker, "speaker-remote")
        XCTAssertEqual(lowConfidence.speaker, "speaker-remote")
    }

    func testSpeakerAttributionDoesNotCarryRemoteIdentityAcrossRecordings() {
        var firstRecording = TranscriptSpeakerAttribution()
        var nextRecording = TranscriptSpeakerAttribution()

        let first = firstRecording.attributedSegment(
            TranscriptSegment(id: 1, text: "Remote voice.", startTime: 0, speaker: nil, confidence: 0.9),
            source: .systemAudio,
            hint: SpeakerAttributionHint(rawSpeakerID: "teams-user-a", confidence: 0.9)
        )
        let next = nextRecording.attributedSegment(
            TranscriptSegment(id: 1, text: "Remote voice.", startTime: 0, speaker: nil, confidence: 0.9),
            source: .systemAudio,
            hint: SpeakerAttributionHint(rawSpeakerID: "teams-user-z", confidence: 0.9)
        )

        XCTAssertEqual(first.speaker, "speaker-remote-1")
        XCTAssertEqual(next.speaker, "speaker-remote-1")
    }

    func testTranscriptSpeakerLabelsFindsUntaggedSpeakersInFirstSeenOrder() {
        let segments = [
            TranscriptSegment(id: 1, text: "Local voice.", startTime: 0, speaker: "speaker-local", confidence: 0.9),
            TranscriptSegment(id: 2, text: "Remote voice.", startTime: 4, speaker: "speaker-remote-1", confidence: 0.9),
            TranscriptSegment(id: 3, text: "More remote voice.", startTime: 6, speaker: "speaker-remote-2", confidence: 0.9),
            TranscriptSegment(id: 4, text: "Remote voice repeated.", startTime: 7, speaker: "speaker-remote-1", confidence: 0.9),
            TranscriptSegment(id: 5, text: "Warning.", startTime: 7, speaker: "System", confidence: 1)
        ]
        let profiles = [
            "speaker-local": SpeakerProfile(speakerID: "speaker-local", name: "JP")
        ]

        let untagged = TranscriptSpeakerLabels.untaggedSpeakerIDs(
            in: segments,
            profiles: profiles,
            deferredSpeakerIDs: []
        )

        XCTAssertEqual(untagged, ["speaker-remote-1", "speaker-remote-2"])
    }

    func testTranscriptionWindowPlannerSplitsLongBuffersIntoBoundedWindows() {
        let windows = TranscriptionWindowPlanner.windows(
            frameLength: 75 * 16_000,
            sampleRate: 16_000,
            maxDuration: 30
        )

        XCTAssertEqual(windows.map(\.startFrame), [0, 480_000, 960_000])
        XCTAssertEqual(windows.map(\.frameCount), [480_000, 480_000, 240_000])
        XCTAssertEqual(windows.map(\.startTime), [0, 30, 60])
        XCTAssertTrue(windows.allSatisfy { $0.duration <= 30 })
    }

    func testTranscriptionWarningSegmentPreservesSharedTranscriptShape() {
        let warning = TranscriptionWindowPlanner.warningSegment(
            id: 4,
            startTime: 30,
            endTime: 45,
            reason: "Whisper chunk failed"
        )

        XCTAssertEqual(warning.id, 4)
        XCTAssertEqual(warning.text, "[Transcript may be incomplete: Whisper chunk failed]")
        XCTAssertEqual(warning.startTime, 30)
        XCTAssertEqual(warning.endTime, 45)
        XCTAssertEqual(warning.speaker, "System")
        XCTAssertEqual(warning.confidence, 0)
    }

    func testAITasksExtractJSONFromMarkdownFence() throws {
        let raw = """
        Sure:
        ```json
        {"decisions":["Go"],"actionItems":[{"task":"Email","owner":"Ana","deadline":null}],"topics":["Launch"],"openQuestions":[]}
        ```
        """

        let summary = try AITasks.parseMeetingSummary(raw)

        XCTAssertEqual(summary.decisions, ["Go"])
        XCTAssertEqual(summary.actionItems.first?.task, "Email")
        XCTAssertTrue(summary.wasSummarized)
    }

    func testAITasksReportsMalformedSummaryAsParseError() {
        let truncated = """
        {"decisions":["Go"],"actionItems":[],"topics":["Launch"
        """

        XCTAssertThrowsError(try AITasks.parseMeetingSummary(truncated)) { error in
            guard case SummarizationError.parseError = error else {
                return XCTFail("Expected a summarization parse error, got \(error)")
            }
        }
    }

    func testSummarizationEngineUsesInjectedClientForStructuredSummary() async throws {
        let client = SequencedLLMClient(responses: [
            """
            {"decisions":["Proceed"],"actionItems":[],"topics":["Inference"],"openQuestions":[]}
            """
        ])
        let engine = SummarizationEngine(
            client: client,
            provider: .nvidia,
            model: "test-model",
            template: .general
        )

        let summary = try await engine.summarize(transcript: "A short transcript")
        let requestCount = await client.requestCount
        let prompts = await client.recordedPrompts()

        XCTAssertEqual(summary.decisions, ["Proceed"])
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(prompts[0].contains("At most 5 decisions, 8 action items, 8 topics, and 5 open questions"))
        XCTAssertTrue(prompts[0].contains("Keep every string under 160 characters"))
    }

    func testSummarizationEngineRetriesMalformedOutputWithConciseRecoveryPrompt() async throws {
        let client = SequencedLLMClient(responses: [
            """
            {"decisions":["Proceed"],"actionItems":[],"topics":["Inference"
            """,
            """
            {"decisions":["Proceed"],"actionItems":[],"topics":["Inference"],"openQuestions":[]}
            """
        ])
        let engine = SummarizationEngine(
            client: client,
            provider: .nvidia,
            model: "test-model",
            template: .general
        )

        let summary = try await engine.summarize(transcript: "A long transcript")
        let prompts = await client.recordedPrompts()

        XCTAssertEqual(summary.decisions, ["Proceed"])
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts[1].contains("RECOVERY ATTEMPT"))
        XCTAssertTrue(prompts[1].contains("Keep every string under 120 characters"))
    }

    func testSummarizationEngineRetriesWhenProviderReportsTokenLimit() async throws {
        let client = SequencedLLMClient(results: [
            .failure(.responseTruncated),
            .success(
                """
                {"decisions":["Proceed"],"actionItems":[],"topics":["Inference"],"openQuestions":[]}
                """
            )
        ])
        let engine = SummarizationEngine(
            client: client,
            provider: .nvidia,
            model: "test-model",
            template: .general
        )

        let summary = try await engine.summarize(transcript: "A long transcript")
        let requestCount = await client.requestCount

        XCTAssertEqual(summary.decisions, ["Proceed"])
        XCTAssertEqual(requestCount, 2)
    }

    func testGPT61SolSummaryRetriesSameModelThroughAlternateHubRoute() async throws {
        let client = SequencedLLMClient(results: [
            .failure(.apiError(statusCode: 503, message: "Temporarily unavailable")),
            .success("""
            {"decisions":["Proceed"],"actionItems":[],"topics":["Inference"],"openQuestions":[]}
            """),
        ])
        let engine = SummarizationEngine(
            client: client,
            provider: .nvidia,
            model: "azure/openai/gpt-6.1-sol"
        )

        let summary = try await engine.summarize(transcript: "We decided to proceed.")
        let models = await client.recordedModels()

        XCTAssertEqual(summary.decisions, ["Proceed"])
        XCTAssertEqual(models, ["azure/openai/gpt-6.1-sol", "openai/openai/gpt-6.1-sol"])
    }

    func testGPT61SolSummaryReportsFailureAfterBothSameModelRoutesFail() async throws {
        let client = SequencedLLMClient(results: [
            .failure(.apiError(statusCode: 503, message: "Temporarily unavailable")),
            .failure(.apiError(statusCode: 503, message: "Temporarily unavailable")),
        ])
        let engine = SummarizationEngine(
            client: client,
            provider: .nvidia,
            model: "azure/openai/gpt-6.1-sol"
        )

        do {
            _ = try await engine.summarize(transcript: "We decided to proceed.")
            XCTFail("Expected the unavailable GPT-6.1 routes to report failure")
        } catch {
            XCTAssertEqual((error as? SummarizationError)?.statusCode, 503)
        }
        let models = await client.recordedModels()
        XCTAssertEqual(models, ["azure/openai/gpt-6.1-sol", "openai/openai/gpt-6.1-sol"])
    }

    func testOpenRouterCompletionParserReturnsCompletedContent() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [[
                "finish_reason": "stop",
                "message": ["content": "{\"decisions\":[]}"]
            ]]
        ])

        XCTAssertEqual(try OpenRouterClient.responseText(from: data), "{\"decisions\":[]}")
    }

    func testOpenRouterCompletionParserRejectsTokenLimitedOutput() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "choices": [[
                "finish_reason": "length",
                "message": ["content": "{\"decisions\":[\"Incomplete"]
            ]]
        ])

        XCTAssertThrowsError(try OpenRouterClient.responseText(from: data)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The model stopped before completing the summary response."
            )
        }
    }

    func testParsedActionItemsUseDeterministicContentIDs() throws {
        let raw = """
        {"decisions":[],"actionItems":[{"task":"Email the launch brief","owner":"Ana","deadline":"2026-05-08"},{"task":"Email  the launch brief","owner":" ana ","deadline":"2026-05-08"}],"topics":[],"openQuestions":[]}
        """

        let summary = try AITasks.parseMeetingSummary(raw)

        XCTAssertEqual(summary.actionItems.count, 1)
        XCTAssertEqual(
            summary.actionItems.first?.id,
            ActionItem.stableID(task: "Email the launch brief", owner: "Ana", deadline: "2026-05-08")
        )
    }

    func testLegacySummaryDecodesWithGeneratedSectionMetadata() throws {
        let data = """
        {"decisions":["Ship"],"actionItems":[],"topics":["Launch"],"openQuestions":[],"wasSummarized":true}
        """.data(using: .utf8)!

        let summary = try JSONDecoder().decode(MeetingSummary.self, from: data)

        XCTAssertEqual(summary.metadata(for: .decisions).state, .generated)
        XCTAssertEqual(summary.metadata(for: .actionItems).state, .generated)
        XCTAssertEqual(summary.metadata(for: .topics).state, .generated)
        XCTAssertEqual(summary.metadata(for: .openQuestions).state, .generated)
    }

    func testReplacingOneSummarySectionPreservesOtherUserEdits() {
        let editedAt = Date(timeIntervalSince1970: 100)
        let regeneratedAt = Date(timeIntervalSince1970: 200)
        var summary = MeetingSummary(
            decisions: ["User edited decision"],
            actionItems: [ActionItem(task: "Keep customer follow-up", owner: "Bo")],
            topics: ["Old topic"],
            openQuestions: ["Existing question"],
            wasSummarized: true,
            sectionMetadata: [
                MeetingSummarySection.decisions.rawValue: SummarySectionEditMetadata(state: .userEdited, modifiedAt: editedAt),
                MeetingSummarySection.actionItems.rawValue: SummarySectionEditMetadata(state: .userEdited, modifiedAt: editedAt),
            ]
        )

        summary.replace(.topics, with: .topics(["Regenerated topic"]), state: .generated, modifiedAt: regeneratedAt)

        XCTAssertEqual(summary.decisions, ["User edited decision"])
        XCTAssertEqual(summary.actionItems.map(\.task), ["Keep customer follow-up"])
        XCTAssertEqual(summary.topics, ["Regenerated topic"])
        XCTAssertEqual(summary.openQuestions, ["Existing question"])
        XCTAssertEqual(summary.metadata(for: .decisions).state, .userEdited)
        XCTAssertEqual(summary.metadata(for: .actionItems).state, .userEdited)
        XCTAssertEqual(summary.metadata(for: .topics).state, .generated)
        XCTAssertEqual(summary.metadata(for: .topics).modifiedAt, regeneratedAt)
    }

    func testMeetingSummaryActionItemsAreNotAutoSyncedIntoTasks() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/App/MeetingManager.swift"))

        XCTAssertFalse(source.contains("syncActionItemsToTasks"))
        XCTAssertFalse(source.contains("mergingActionLinkedTasks(existing: tasks, meeting: meeting)"))
    }

    func testMeetingSummaryDoesNotShowAutoLinkedTaskSection() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/MeetingLibrary/NotionPageView.swift"))

        XCTAssertFalse(source.contains("linkedTasksSection"))
        XCTAssertFalse(source.contains("Linked Tasks"))
        XCTAssertFalse(source.contains("tasksLinked(to: meeting.id)"))
    }

    func testMeetingSummaryUsesSingleFullRegenerateAction() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/MeetingLibrary/NotionPageView.swift"))

        XCTAssertTrue(source.contains("summaryRegenerateButton"))
        XCTAssertTrue(source.contains("Text(\"Regenerate summary\")"))
        XCTAssertTrue(source.contains("regenerateSummary()"))
        XCTAssertEqual(source.components(separatedBy: "Text(\"Regenerate summary\")").count - 1, 1)
    }

    func testMeetingSummaryDoesNotExposePerSectionRegenerateActions() throws {
        let source = try String(contentsOf: repositoryRoot()
            .appendingPathComponent("NoteAI/UI/MeetingLibrary/NotionPageView.swift"))

        XCTAssertFalse(source.contains("regenerateSection("))
        XCTAssertFalse(source.contains("regeneratingSection"))
        XCTAssertFalse(source.contains("sectionRegenerateError"))
    }

    func testCommandCenterLayoutUsesCodexReadableTypographyScale() {
        let compact = CommandCenterLayout.metrics(forWindowWidth: 980)
        let wide = CommandCenterLayout.metrics(forWindowWidth: 1700)

        XCTAssertLessThan(compact.scale, wide.scale)
        XCTAssertLessThan(compact.sidebarWidth, wide.sidebarWidth)
        XCTAssertLessThan(compact.commandSearchMaxWidth, wide.commandSearchMaxWidth)
        XCTAssertLessThan(compact.contentMaxWidth, wide.contentMaxWidth)
        XCTAssertLessThan(compact.onboardingMinimumCardWidth, wide.onboardingMinimumCardWidth)

        XCTAssertGreaterThanOrEqual(wide.sidebarWidth, 260)
        XCTAssertLessThanOrEqual(wide.sidebarWidth, 280)
        XCTAssertGreaterThanOrEqual(wide.maximumSidebarWidth, 320)
        XCTAssertGreaterThanOrEqual(wide.contentMaxWidth, 1300)
        XCTAssertLessThanOrEqual(wide.scale, 1)
        XCTAssertEqual(wide.titleFontSize, 28)
        XCTAssertEqual(wide.metricValueFontSize, 22)
        XCTAssertEqual(wide.sectionTitleFontSize, 15)
        XCTAssertEqual(wide.bodyFontSize, 14)
        XCTAssertEqual(wide.smallFontSize, 12)
        XCTAssertEqual(wide.tinyFontSize, 11)

        XCTAssertGreaterThanOrEqual(compact.bodyFontSize, 13)
        XCTAssertGreaterThanOrEqual(compact.smallFontSize, 12)
        XCTAssertGreaterThanOrEqual(compact.tinyFontSize, 11)
        XCTAssertLessThanOrEqual(compact.titleFontSize, 27)

        XCTAssertLessThanOrEqual(wide.controlHeight, 39)
        XCTAssertLessThanOrEqual(wide.actionButtonHeight, 42)
    }

    func testThemeUsesCodexLikeNeutralPaletteAndTitleScale() throws {
        let source = try themeSource()

        XCTAssertTrue(source.contains("static let notionWindowBG = Color(light: \"FFFFFF\", dark: \"101010\")"))
        XCTAssertTrue(source.contains("static let notionTopBarBG = Color(light: \"F7F7F7\", dark: \"151515\")"))
        XCTAssertTrue(source.contains("static let notionSidebarBG = Color(light: \"F7F7F7\", dark: \"181818\")"))
        XCTAssertTrue(source.contains("static let notionSurfaceBG = Color(light: \"FFFFFF\", dark: \"191919\")"))
        XCTAssertTrue(source.contains("static let notionHoverBG = Color(light: \"EFEFEF\", dark: \"252525\")"))
        XCTAssertTrue(source.contains("static let notionSelectedBG = Color(light: \"EDEDED\", dark: \"303030\")"))
        XCTAssertTrue(source.contains("static let notionBorder = Color(light: \"DCDCDC\", dark: \"2A2A2A\")"))
        XCTAssertTrue(source.contains("static let textPrimary = Color(light: \"1F1F1F\", dark: \"F4F4F4\")"))
        XCTAssertTrue(source.contains("static let textSecondary = Color(light: \"4A4A4A\", dark: \"D6D6D6\")"))
        XCTAssertTrue(source.contains("static let textTertiary = Color(light: \"787878\", dark: \"9B9B9B\")"))
        XCTAssertTrue(source.contains("static let pageTitleSize: CGFloat = 34"))
        XCTAssertTrue(source.contains("static let h2Size: CGFloat = 22"))
        XCTAssertTrue(source.contains("static let h3Size: CGFloat = 18"))
        XCTAssertTrue(source.contains("static let bodySize: CGFloat = 14"))
        XCTAssertTrue(source.contains("static let smallSize: CGFloat = 12"))
    }

    func testPrimaryPageTitlesUseCodexLikeSemiboldWeight() throws {
        let homeSource = try homeDashboardSource()
        let meetingPageSource = try notionPageSource()

        XCTAssertTrue(homeSource.contains(".font(.system(size: layout.titleFontSize, weight: .semibold))"))
        XCTAssertTrue(meetingPageSource.contains(".font(.system(size: Theme.pageTitleSize, weight: .semibold))"))
        XCTAssertFalse(homeSource.contains(".font(.system(size: layout.titleFontSize, weight: .bold))"))
        XCTAssertFalse(meetingPageSource.contains(".font(.system(size: Theme.pageTitleSize, weight: .bold))"))
    }

    func testAppearanceModeMapsToPreferredColorScheme() {
        XCTAssertEqual(NoteAIAppearanceMode.allCases.map(\.rawValue), ["system", "dark", "light"])
        XCTAssertNil(NoteAIAppearanceMode.system.preferredColorScheme)
        XCTAssertEqual(NoteAIAppearanceMode.dark.preferredColorScheme, .dark)
        XCTAssertEqual(NoteAIAppearanceMode.light.preferredColorScheme, .light)
    }

    func testCommandCenterLayoutPresetsChangeDensityAndSpacing() {
        let compact = CommandCenterLayout.metrics(forWindowWidth: 1400, preset: .compact)
        let balanced = CommandCenterLayout.metrics(forWindowWidth: 1400, preset: .balanced)
        let comfortable = CommandCenterLayout.metrics(forWindowWidth: 1400, preset: .comfortable)

        XCTAssertLessThan(compact.dashboardSpacing, balanced.dashboardSpacing)
        XCTAssertLessThan(compact.panelPadding, balanced.panelPadding)
        XCTAssertLessThan(compact.onboardingMinimumCardWidth, balanced.onboardingMinimumCardWidth)

        XCTAssertGreaterThan(comfortable.dashboardSpacing, balanced.dashboardSpacing)
        XCTAssertGreaterThan(comfortable.panelPadding, balanced.panelPadding)
        XCTAssertGreaterThan(comfortable.onboardingMinimumCardWidth, balanced.onboardingMinimumCardWidth)

        XCTAssertEqual(CommandCenterLayoutPreset.allCases.map(\.rawValue), ["compact", "balanced", "comfortable"])
    }

    func testSettingsExposeAppearanceAndLayoutControls() throws {
        let source = try settingsSource()

        XCTAssertTrue(source.contains("AppearanceSettingsView"))
        XCTAssertTrue(source.contains("@AppStorage(\"noteai.appearanceMode\")"))
        XCTAssertTrue(source.contains("@AppStorage(\"noteai.commandCenterLayoutPreset\")"))
        XCTAssertTrue(source.contains("Picker(\"Appearance\""))
        XCTAssertTrue(source.contains("Picker(\"Meeting layout\""))
    }

    func testMainWindowAppliesSavedAppearanceAndLayoutPreset() throws {
        let appSource = try appDelegateSource()
        let meetingSource = try meetingLibrarySource()

        XCTAssertTrue(appSource.contains(".preferredColorScheme(NoteAIAppearanceMode"))
        XCTAssertTrue(meetingSource.contains("CommandCenterLayoutPreset(rawValue: commandCenterLayoutPresetRaw)"))
        XCTAssertTrue(meetingSource.contains("CommandCenterLayout.metrics(forWindowWidth: proxy.size.width, preset: layoutPreset)"))
    }

    func testCommandCenterSidebarBrandReservesTitlebarControls() throws {
        let compact = CommandCenterLayout.metrics(forWindowWidth: 980)
        let wide = CommandCenterLayout.metrics(forWindowWidth: 1700)
        let source = try meetingLibrarySource()

        XCTAssertGreaterThanOrEqual(compact.sidebarBrandLeadingInset, 12)
        XCTAssertLessThanOrEqual(compact.sidebarBrandLeadingInset, 18)
        XCTAssertLessThanOrEqual(compact.sidebarBrandHeaderHeight, 58)
        XCTAssertLessThanOrEqual(compact.sidebarBrandHeaderTopPadding, 18)
        XCTAssertLessThanOrEqual(compact.sidebarBrandHeaderBottomPadding, 8)
        XCTAssertEqual(compact.sidebarBrandLeadingInset, wide.sidebarBrandLeadingInset)
        XCTAssertTrue(source.contains(".padding(.leading, layout.sidebarBrandLeadingInset)"))
        XCTAssertTrue(source.contains(".padding(.top, layout.sidebarBrandHeaderTopPadding)"))
        XCTAssertTrue(source.contains(".padding(.bottom, layout.sidebarBrandHeaderBottomPadding)"))
        XCTAssertTrue(source.contains(".frame(height: layout.sidebarBrandHeaderHeight"))
    }

    func testCommandCenterSidebarBrandCentersLogoOnly() throws {
        let source = try meetingLibrarySource()
        let brandHeaderStart = try XCTUnwrap(source.range(of: "private func brandHeader(layout: CommandCenterLayout) -> some View"))
        let nextFunction = try XCTUnwrap(source.range(of: "private func searchAndFilters", range: brandHeaderStart.upperBound..<source.endIndex))
        let brandHeaderSource = String(source[brandHeaderStart.lowerBound..<nextFunction.lowerBound])

        XCTAssertTrue(brandHeaderSource.contains(".font(.system(size: layout.sectionTitleFontSize + 11, weight: .medium))"))
        XCTAssertTrue(brandHeaderSource.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)"))
        XCTAssertFalse(brandHeaderSource.contains("Text(\"NoteAI\")"))
        XCTAssertFalse(brandHeaderSource.contains("Text(\"v5.0\")"))
        XCTAssertTrue(brandHeaderSource.contains("Image(systemName: \"magnifyingglass\")"))
        XCTAssertTrue(brandHeaderSource.contains(".frame(height: layout.sidebarBrandHeaderHeight, alignment: .center)"))
    }

    func testCollapsedSidebarSearchDoesNotReserveVerticalSpace() throws {
        let source = try meetingLibrarySource()
        let searchAndFiltersStart = try XCTUnwrap(source.range(of: "private func searchAndFilters(layout: CommandCenterLayout) -> some View"))
        let nextFunction = try XCTUnwrap(source.range(of: "private func sidebarSection", range: searchAndFiltersStart.upperBound..<source.endIndex))
        let searchAndFiltersSource = String(source[searchAndFiltersStart.lowerBound..<nextFunction.lowerBound])

        XCTAssertTrue(searchAndFiltersSource.contains("if sidebarSearchExpanded || searchIsActive"))
        XCTAssertTrue(searchAndFiltersSource.contains("EmptyView()"))
        XCTAssertFalse(searchAndFiltersSource.contains(".padding(.vertical, round(10 * layout.scale))"))
    }

    func testSidebarRecordingControlsDoNotRenderStaticSourceCards() throws {
        let source = try meetingLibrarySource()

        XCTAssertFalse(source.contains("recordingSourceCard("))
        XCTAssertFalse(source.contains("Native capture"))
        XCTAssertFalse(source.contains("subtitle: \"Ready\""))
        XCTAssertFalse(source.contains("recordingReadinessRow(readiness"))
        XCTAssertFalse(source.contains("private func recordingReadinessRow"))
    }

    func testSidebarRecordingControlsUsesReadinessOnlyForPrimaryActionLabel() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("recordingReadiness.primaryActionTitle"))
        XCTAssertTrue(source.contains("meetingManager.startRecording()"))
    }

    func testTopBarRecordingControlUsesMeetingIconOnlyIdleButton() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("Image(systemName: LibraryListPresentation.SidebarItemKind.meeting.icon)"))
        XCTAssertTrue(source.contains("LibraryListPresentation.SidebarItemKind.meeting.tint.opacity(0.95)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(Text(recordButtonLabel))"))
        XCTAssertTrue(source.contains(".frame(width: round(34 * layout.scale), height: round(34 * layout.scale))"))
        XCTAssertTrue(source.contains("LibraryListPresentation.SidebarItemKind.meeting.tint.opacity(0.08)"))
        XCTAssertTrue(source.contains("LibraryListPresentation.SidebarItemKind.meeting.tint.opacity(0.42)"))
        XCTAssertFalse(source.contains("Label(compactRecordButtonLabel"))
        XCTAssertFalse(source.contains("compactRecordButtonLabel"))
        XCTAssertFalse(source.contains("LinearGradient(colors: [Theme.danger, Color(hex: \"FF8A5C\")]"))
        XCTAssertFalse(source.contains(".frame(height: layout.actionButtonHeight)"))
    }

    func testTopBarRecordingControlDoesNotContinuouslyAnimateWhileRecording() throws {
        let source = try meetingLibrarySource()
        let controlStart = try XCTUnwrap(
            source.range(of: "private func topBarRecordingControl(layout: CommandCenterLayout) -> some View")
        )
        let nextFunction = try XCTUnwrap(
            source.range(of: "private func sidebar(layout: CommandCenterLayout)", range: controlStart.upperBound..<source.endIndex)
        )
        let controlSource = String(source[controlStart.lowerBound..<nextFunction.lowerBound])

        XCTAssertTrue(controlSource.contains(".fill(Theme.danger)"))
        XCTAssertFalse(controlSource.contains("repeatForever"))
        XCTAssertFalse(controlSource.contains("pulseAnimation"))
        XCTAssertFalse(controlSource.contains(".onAppear { withAnimation"))
    }

    func testNotionInspiredThemeTokensUseCodexNeutralPalette() throws {
        let source = try themeSource()

        XCTAssertTrue(source.contains("notionWindowBG"))
        XCTAssertTrue(source.contains("notionTopBarBG"))
        XCTAssertTrue(source.contains("notionActiveTabBG"))
        XCTAssertTrue(source.contains("notionIconAccent"))
        XCTAssertTrue(source.contains("dark: \"101010\""))
        XCTAssertTrue(source.contains("dark: \"151515\""))
        XCTAssertTrue(source.contains("dark: \"303030\""))
        XCTAssertFalse(source.contains("dark: \"0B0F12\""))
        XCTAssertFalse(source.contains("dark: \"10161B\""))
    }

    func testCommandCenterRendersNotionStyleTabStripInTopChrome() throws {
        let source = try meetingLibrarySource()
        let commandBarStart = try XCTUnwrap(source.range(of: "private func commandBar(layout: CommandCenterLayout) -> some View"))
        let nextFunction = try XCTUnwrap(source.range(of: "private func notionTabBar", range: commandBarStart.upperBound..<source.endIndex))
        let commandBarSource = String(source[commandBarStart.lowerBound..<nextFunction.lowerBound])

        XCTAssertTrue(commandBarSource.contains("notionTabBar(layout: layout)"))
        XCTAssertTrue(commandBarSource.contains("topBarRecordingControl(layout: layout)"))
        XCTAssertTrue(source.contains("private func notionTabBar(layout: CommandCenterLayout) -> some View"))
        XCTAssertTrue(source.contains("private func notionTabTitle() -> String"))
        XCTAssertTrue(source.contains("private func notionTabIcon() -> String"))
        XCTAssertTrue(source.contains("private func notionTabAccent() -> Color"))
        XCTAssertTrue(source.contains("Theme.notionActiveTabBG"))
    }

    func testNotionTabsShowSideBySideWithCloseButtonsAndSidebarSearchIcon() throws {
        let source = try meetingLibrarySource()
        let commandBarStart = try XCTUnwrap(source.range(of: "private func commandBar(layout: CommandCenterLayout) -> some View"))
        let nextFunction = try XCTUnwrap(source.range(of: "private func notionTabBar", range: commandBarStart.upperBound..<source.endIndex))
        let commandBarSource = String(source[commandBarStart.lowerBound..<nextFunction.lowerBound])
        let brandHeaderStart = try XCTUnwrap(source.range(of: "private func brandHeader(layout: CommandCenterLayout) -> some View"))
        let searchAndFiltersStart = try XCTUnwrap(source.range(of: "private func searchAndFilters(layout: CommandCenterLayout) -> some View"))
        let brandHeaderSource = String(source[brandHeaderStart.lowerBound..<searchAndFiltersStart.lowerBound])

        XCTAssertTrue(source.contains("@State private var openTabs: [SidebarSelection] = [.home]"))
        XCTAssertTrue(source.contains("ForEach(openTabs, id: \\.self)"))
        XCTAssertTrue(source.contains("closeTab(tab)"))
        XCTAssertTrue(source.contains("Image(systemName: \"xmark\")"))
        XCTAssertTrue(source.contains("private func activateSelection(_ target: SidebarSelection?)"))
        XCTAssertTrue(source.contains("private func registerOpenTab(_ target: SidebarSelection)"))
        XCTAssertTrue(commandBarSource.contains("notionTabBar(layout: layout)"))
        XCTAssertFalse(commandBarSource.contains("TextField("))
        XCTAssertTrue(brandHeaderSource.contains("Image(systemName: \"magnifyingglass\")"))
        XCTAssertTrue(brandHeaderSource.contains("sidebarSearchExpanded.toggle()"))
        XCTAssertTrue(source.contains("if sidebarSearchExpanded || searchIsActive"))
    }

    func testNotionTabBarDoesNotReserveSpaceForNewNotePlusButton() throws {
        let source = try meetingLibrarySource()
        let tabBarStart = try XCTUnwrap(source.range(of: "private func notionTabBar(layout: CommandCenterLayout) -> some View"))
        let nextFunction = try XCTUnwrap(source.range(of: "private func notionTabButton", range: tabBarStart.upperBound..<source.endIndex))
        let tabBarSource = String(source[tabBarStart.lowerBound..<nextFunction.lowerBound])

        XCTAssertTrue(tabBarSource.contains("ForEach(openTabs, id: \\.self)"))
        XCTAssertFalse(tabBarSource.contains("createNewNote()"))
        XCTAssertFalse(tabBarSource.contains("Image(systemName: \"plus\")"))
        XCTAssertFalse(tabBarSource.contains(".help(\"New note\")"))
    }

    func testNotionTabBarUsesAvailableTopChromeWidthBeforeRightControls() throws {
        let source = try meetingLibrarySource()
        let commandBarStart = try XCTUnwrap(source.range(of: "private func commandBar(layout: CommandCenterLayout) -> some View"))
        let tabBarStart = try XCTUnwrap(source.range(of: "private func notionTabBar", range: commandBarStart.upperBound..<source.endIndex))
        let commandBarSource = String(source[commandBarStart.lowerBound..<tabBarStart.lowerBound])
        let nextFunction = try XCTUnwrap(source.range(of: "private func notionTabButton", range: tabBarStart.upperBound..<source.endIndex))
        let tabBarSource = String(source[tabBarStart.lowerBound..<nextFunction.lowerBound])
        let tabBarCallRange = try XCTUnwrap(commandBarSource.range(of: "notionTabBar(layout: layout)"))
        let rightControlRange = try XCTUnwrap(commandBarSource.range(of: "topBarRecordingControl(layout: layout)"))
        let betweenTabBarAndControls = String(commandBarSource[tabBarCallRange.upperBound..<rightControlRange.lowerBound])

        XCTAssertFalse(betweenTabBarAndControls.contains("Spacer()"))
        XCTAssertTrue(betweenTabBarAndControls.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
        XCTAssertTrue(betweenTabBarAndControls.contains(".layoutPriority(1)"))
        XCTAssertFalse(tabBarSource.contains(".frame(maxWidth: round("))
        XCTAssertTrue(tabBarSource.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    func testSidebarChromeDoesNotRenderQuickFilterButtons() throws {
        let source = try meetingLibrarySource()
        let searchAndFiltersStart = try XCTUnwrap(source.range(of: "private func searchAndFilters(layout: CommandCenterLayout) -> some View"))
        let nextFunction = try XCTUnwrap(source.range(of: "private func sidebarSection", range: searchAndFiltersStart.upperBound..<source.endIndex))
        let searchAndFiltersSource = String(source[searchAndFiltersStart.lowerBound..<nextFunction.lowerBound])

        XCTAssertFalse(source.contains("CommandCenterQuickFilter"))
        XCTAssertFalse(source.contains("@State private var quickFilter"))
        XCTAssertFalse(source.contains("private func quickFilterButton"))
        XCTAssertFalse(searchAndFiltersSource.contains("Recent"))
        XCTAssertFalse(searchAndFiltersSource.contains("Open"))
        XCTAssertFalse(searchAndFiltersSource.contains("Unreviewed"))
    }

    func testNotionShellUsesFlatterSidebarAndDocumentSurfaces() throws {
        let meetingSource = try meetingLibrarySource()
        let homeSource = try homeDashboardSource()

        XCTAssertTrue(meetingSource.contains(".background(Theme.notionSidebarBG)"))
        XCTAssertTrue(meetingSource.contains("Theme.notionHoverBG"))
        XCTAssertTrue(meetingSource.contains("Theme.notionSelectedBG"))
        XCTAssertTrue(meetingSource.contains(".background(Theme.notionWindowBG)"))
        XCTAssertTrue(homeSource.contains(".background(Theme.notionSurfaceBG, in: RoundedRectangle(cornerRadius: 6))"))
        XCTAssertFalse(homeSource.contains("cornerRadius: 14"))
    }

    func testSidebarListLimiterShowsInitialItemsAndCountsHiddenItems() {
        let items = Array(1...8)

        let collapsed = SidebarListLimiter.slice(items, expanded: false, searchActive: false, limit: 5)
        XCTAssertEqual(collapsed.items, [1, 2, 3, 4, 5])
        XCTAssertEqual(collapsed.hiddenCount, 3)
        XCTAssertTrue(collapsed.canToggle)

        let expanded = SidebarListLimiter.slice(items, expanded: true, searchActive: false, limit: 5)
        XCTAssertEqual(expanded.items, items)
        XCTAssertEqual(expanded.hiddenCount, 0)
        XCTAssertTrue(expanded.canToggle)

        let searching = SidebarListLimiter.slice(items, expanded: false, searchActive: true, limit: 5)
        XCTAssertEqual(searching.items, items)
        XCTAssertEqual(searching.hiddenCount, 0)
        XCTAssertFalse(searching.canToggle)
    }

    func testSidebarShowMoreAffordanceIsPersistedAndScoped() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("@AppStorage(\"noteai.sidebarExpandedLists.v1\")"))
        XCTAssertTrue(source.contains("Show more"))
        XCTAssertTrue(source.contains("Show less"))
        XCTAssertTrue(source.contains("sidebarLimitedContent"))
        XCTAssertTrue(source.contains("sidebarListToggleRow"))
    }

    func testSidebarSectionHeaderSelectsMeetingHistory() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("selectionTarget: .meetingsList"))
        XCTAssertTrue(source.contains("private func sidebarSectionHeaderButton"))
        XCTAssertTrue(source.contains("selection = selectionTarget"))
    }

    func testMeetingHistoryAndSavedMeetingsRenderInMainDetailArea() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("case .meetingsList = selection"))
        XCTAssertTrue(source.contains("meetingsListPage"))
        XCTAssertTrue(source.contains("NotionPageView(meeting: meeting"))
        XCTAssertTrue(source.contains("private func collectionListPage"))
        XCTAssertTrue(source.contains("private func collectionListRow"))
    }

    func testSidebarDividerIsFullHeightShellChrome() throws {
        let source = try meetingLibrarySource()

        XCTAssertTrue(source.contains("private let sidebarDividerHitWidth"))
        XCTAssertTrue(source.contains("sidebarResizeDivider(layout: layout, effectiveSidebarWidth: effectiveSidebarWidth)"))
        XCTAssertTrue(source.contains("private func sidebarResizeDivider"))
        XCTAssertTrue(source.contains(".ignoresSafeArea(edges: .top)"))
        XCTAssertFalse(source.contains("Rectangle()\n                        .fill(Theme.border)\n                        .frame(width: 1)\n                        .contentShape(Rectangle())"))
    }

    func testRichMarkdownEditorUsesAppContentBackground() throws {
        let editorSource = try richMarkdownEditorSource()
        let themeSource = try themeSource()

        XCTAssertTrue(themeSource.contains("static let contentBGNSColor"))
        XCTAssertTrue(editorSource.contains("RichMarkdownEditorTheme.background"))
        XCTAssertTrue(editorSource.contains("textView.backgroundColor = RichMarkdownEditorTheme.background"))
        XCTAssertTrue(editorSource.contains("scrollView.backgroundColor = RichMarkdownEditorTheme.background"))
        XCTAssertFalse(editorSource.contains("textView.backgroundColor = NSColor(red: 0.122"))
        XCTAssertFalse(editorSource.contains("layer?.backgroundColor = NSColor(red: 0.122"))
    }

    func testRichMarkdownEditorCodeBlocksUseAppContentBackground() throws {
        let editorSource = try richMarkdownEditorSource()

        XCTAssertTrue(editorSource.contains("static let codeBlockBackground = Theme.contentBGNSColor"))
        XCTAssertTrue(editorSource.contains("storage.addAttribute(.backgroundColor, value: RichMarkdownEditorTheme.codeBlockBackground"))
        XCTAssertFalse(editorSource.contains("let codeBG = NSColor(white: 0.15"))
    }

    func testMarkdownRendererCodeBlocksUseAppContentBackground() throws {
        let rendererSource = try markdownRendererSource()

        XCTAssertTrue(rendererSource.contains(".background(Theme.contentBG, in: RoundedRectangle(cornerRadius: 8))"))
        XCTAssertFalse(rendererSource.contains(".background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))"))
    }

    func testTranscriptImportIsReachableFromMeetingHistoryForThePrimaryApp() throws {
        let source = try meetingLibrarySource()
        let historyHeader = try sourceFragment(
            named: "private func collectionListPage<Content: View>",
            before: "                if isEmpty {",
            in: source
        )
        let importSheet = try sourceFragment(
            named: ".sheet(isPresented: $showTranscriptImport)",
            before: "    private func resolvedSidebarWidth",
            in: source
        )

        XCTAssertTrue(historyHeader.contains("Label(\"Import transcript\""))
        XCTAssertTrue(historyHeader.contains("showTranscriptImport = true"))
        XCTAssertTrue(historyHeader.contains(".disabled(meetingManager.state != .idle)"))
        XCTAssertFalse(historyHeader.contains("usesTranscriptImportPrimaryFlow"))
        XCTAssertTrue(importSheet.contains("TranscriptImportView"))
        XCTAssertTrue(importSheet.contains("meetingManager.importTranscriptMeeting("))
        XCTAssertTrue(importSheet.contains("selection = .meeting(meeting.id)"))
    }

    func testFocusedShellRetiresStandaloneWorkspacesAndGeneralAssistant() throws {
        let source = try meetingLibrarySource()
        let dashboard = try homeDashboardSource()

        for retiredEntrypoint in ["case notesList", "case tasksList", "case todosList", "case t5tList", "ChatManager", "ChatPanelView", "Save to Note"] {
            XCTAssertFalse(source.contains(retiredEntrypoint), retiredEntrypoint)
        }
        XCTAssertFalse(dashboard.contains("TodoItem"))
        XCTAssertFalse(dashboard.contains("TaskItem"))
        XCTAssertTrue(dashboard.contains("recentMeetingsPanel"))
        XCTAssertTrue(dashboard.contains("onboardingPanel"))
        XCTAssertTrue(source.contains("TranscriptImportView"))
        XCTAssertTrue(source.contains("LiveTranscriptView(meetingManager: meetingManager)"))
    }

    private func meetingLibrarySource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let sidebarFile = projectRoot.appendingPathComponent("NoteAI/UI/MeetingLibrary/MeetingLibraryView.swift")
        return try String(contentsOf: sidebarFile, encoding: .utf8)
    }

    private func notionPageSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let pageFile = projectRoot.appendingPathComponent("NoteAI/UI/MeetingLibrary/NotionPageView.swift")
        return try String(contentsOf: pageFile, encoding: .utf8)
    }

    private func homeDashboardSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let dashboardFile = projectRoot.appendingPathComponent("NoteAI/UI/Home/HomeDashboardView.swift")
        return try String(contentsOf: dashboardFile, encoding: .utf8)
    }

    private func summarizationEngineSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let engineFile = projectRoot.appendingPathComponent("NoteAI/Summarization/SummarizationEngine.swift")
        return try String(contentsOf: engineFile, encoding: .utf8)
    }

    private func settingsSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let settingsFile = projectRoot.appendingPathComponent("NoteAI/UI/Settings/SettingsView.swift")
        return try String(contentsOf: settingsFile, encoding: .utf8)
    }

    private func appDelegateSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let appDelegateFile = projectRoot.appendingPathComponent("NoteAI/App/AppDelegate.swift")
        return try String(contentsOf: appDelegateFile, encoding: .utf8)
    }

    private func richMarkdownEditorSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let editorFile = projectRoot.appendingPathComponent("NoteAI/UI/MarkdownEditor/RichMarkdownEditor.swift")
        return try String(contentsOf: editorFile, encoding: .utf8)
    }

    private func markdownRendererSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let rendererFile = projectRoot.appendingPathComponent("NoteAI/UI/MarkdownEditor/MarkdownRendererView.swift")
        return try String(contentsOf: rendererFile, encoding: .utf8)
    }

    private func themeSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let themeFile = projectRoot.appendingPathComponent("NoteAI/UI/Theme.swift")
        return try String(contentsOf: themeFile, encoding: .utf8)
    }

    func testOAuthCallbackRequiresExpectedState() {
        let valid = "GET /?code=abc123&state=state-1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let missingState = "GET /?code=abc123 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let wrongState = "GET /?code=abc123&state=state-2 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"

        XCTAssertEqual(OAuthCallbackParser.authorizationCode(from: valid, expectedState: "state-1"), "abc123")
        XCTAssertNil(OAuthCallbackParser.authorizationCode(from: missingState, expectedState: "state-1"))
        XCTAssertNil(OAuthCallbackParser.authorizationCode(from: wrongState, expectedState: "state-1"))
    }

    func testOAuthFormBodyPercentEncodesReservedCharacters() {
        let body = OAuthFormURLEncoder.body([
            ("code", "abc+123/with&reserved=value"),
            ("redirect_uri", "http://127.0.0.1:54321/callback"),
        ])

        XCTAssertTrue(body.contains("code=abc%2B123%2Fwith%26reserved%3Dvalue"))
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321%2Fcallback"))
    }

    func testGoogleAccountSessionRequiresTokenAndEmail() {
        XCTAssertEqual(
            GoogleAccountSessionState.resolve(
                accessToken: nil,
                name: "",
                email: "",
                photoURL: "",
                skippedAuth: true
            ),
            .notSignedIn
        )

        XCTAssertEqual(
            GoogleAccountSessionState.resolve(
                accessToken: "token",
                name: "JP Santana",
                email: "jp@example.com",
                photoURL: "https://example.com/avatar.png",
                skippedAuth: true
            ),
            .signedIn(GoogleUserProfile(name: "JP Santana", email: "jp@example.com", photoURL: "https://example.com/avatar.png"))
        )
    }

    func testGoogleUserProfilePayloadRequiresEmail() throws {
        XCTAssertThrowsError(try GoogleUserProfilePayload.profile(from: ["name": "JP Santana"])) { error in
            XCTAssertEqual(error as? GoogleUserProfilePayload.ParseError, .missingEmail)
        }

        let profile = try GoogleUserProfilePayload.profile(from: [
            "name": "JP Santana",
            "email": " jp@example.com ",
            "picture": "https://example.com/avatar.png",
        ])

        XCTAssertEqual(profile.name, "JP Santana")
        XCTAssertEqual(profile.email, "jp@example.com")
        XCTAssertEqual(profile.photoURL, "https://example.com/avatar.png")
    }

    func testLibraryListPresentationUsesShortNumericDates() throws {
        let calendar = Calendar(identifier: .gregorian)
        let meetingDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 18)))

        XCTAssertEqual(LibraryListPresentation.shortDateString(for: meetingDate), "05/18/26")
    }

    func testMeetingSidebarUsesWaveformPresentation() throws {
        XCTAssertEqual(LibraryListPresentation.SidebarItemKind.meeting.icon, "waveform")

        let source = try meetingLibrarySource()
        let rowSource = try sourceFragment(
            named: "private func sidebarRow(meeting: Meeting, layout: CommandCenterLayout) -> some View",
            before: "    private func homeSidebarRow",
            in: source
        )

        XCTAssertTrue(rowSource.contains("LibraryListPresentation.SidebarItemKind.meeting"))
        XCTAssertTrue(rowSource.contains("Export as Markdown"))
        XCTAssertTrue(rowSource.contains("Export as PDF"))
    }

    func testMeetingHistoryOrdersNewestFirstAndTitlesBreakDateTies() {
        let olderDate = Date(timeIntervalSince1970: 100)
        let newerDate = Date(timeIntervalSince1970: 200)
        let older = Meeting(id: UUID(), title: "Older", date: olderDate, duration: 0, transcript: [], summary: MeetingSummary())
        let newer = Meeting(id: UUID(), title: "Zebra", date: newerDate, duration: 0, transcript: [], summary: MeetingSummary())
        let sameDate = Meeting(id: UUID(), title: "Alpha", date: newerDate, duration: 0, transcript: [], summary: MeetingSummary())

        XCTAssertEqual(LibraryListOrdering.meetings([older, newer, sameDate]).map(\.id), [sameDate.id, newer.id, older.id])
    }

    func testReadAloudTextResolverPrefersSelectedText() {
        XCTAssertEqual(
            ReadAloudTextResolver.textToRead(fallback: "Read the whole note") { " selected sentence " },
            "selected sentence"
        )
        XCTAssertEqual(
            ReadAloudTextResolver.textToRead(fallback: "Read the whole note") { "   \n" },
            "Read the whole note"
        )
        XCTAssertEqual(
            ReadAloudTextResolver.textToRead(fallback: "Read the whole note") { nil },
            "Read the whole note"
        )
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "NoteAITests" {
            url.deleteLastPathComponent()
        }
        url.deleteLastPathComponent()
        return url
    }

    private func sourceFragment(named startMarker: String, before endMarker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(source.range(of: endMarker, range: start.upperBound..<source.endIndex))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

private actor SequencedLLMClient: LLMClient {
    private var results: [Result<String, SummarizationError>]
    private(set) var prompts: [String] = []
    private var models: [String] = []

    init(responses: [String]) {
        results = responses.map(Result.success)
    }

    init(results: [Result<String, SummarizationError>]) {
        self.results = results
    }

    var requestCount: Int { prompts.count }

    func recordedPrompts() -> [String] { prompts }
    func recordedModels() -> [String] { models }

    func complete(prompt: String, model: String) async throws -> String {
        prompts.append(prompt)
        models.append(model)
        guard !results.isEmpty else {
            throw SummarizationError.apiError(statusCode: 500, message: "No stub response")
        }
        return try results.removeFirst().get()
    }
}
