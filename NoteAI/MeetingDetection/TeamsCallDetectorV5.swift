import AppKit
import Combine
import CoreAudio

@MainActor
final class TeamsCallDetectorV5: ObservableObject {
    enum DetectionState: Equatable {
        case disabled
        case monitoring
        case callDetected
        case recording
        case cooldown
    }

    struct StartContext: Equatable {
        var processID: pid_t
        var displayName: String
        var confidence: Double
    }

    @Published var state: DetectionState = .disabled
    @Published var detectedApp: String?
    @Published var confidence: Double = 0
    @Published var evidenceSummary: String = "Disabled"

    var onCallStarted: ((StartContext) -> Void)?
    var onCallEnded: (() -> Void)?

    private var pollingTimer: Timer?
    private var stateMachine = TeamsCallStateMachine(configuration: .default)

    private let pollInterval: TimeInterval = 2
    private let teamsBundleIDs: Set<String> = [
        "com.microsoft.teams",
        "com.microsoft.teams2",
    ]

    func startMonitoring() {
        guard state == .disabled else { return }
        stateMachine = TeamsCallStateMachine(configuration: .default)
        state = .monitoring
        detectedApp = nil
        confidence = 0
        evidenceSummary = "Monitoring Teams"

        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        poll()
        print("[TeamsCallDetectorV5] Started monitoring Teams call state")
    }

    func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        stateMachine = TeamsCallStateMachine(configuration: .default)
        state = .disabled
        detectedApp = nil
        confidence = 0
        evidenceSummary = "Disabled"
        print("[TeamsCallDetectorV5] Stopped monitoring")
    }

    private func poll() {
        let snapshot = currentSnapshot()
        confidence = snapshot.confidenceScore
        evidenceSummary = summary(for: snapshot)

        let events = stateMachine.process(snapshot)
        for event in events {
            handle(event)
        }

        switch stateMachine.state.kind {
        case .idle where state != .disabled:
            state = .monitoring
        case .callDetected:
            state = .callDetected
        case .recording:
            state = .recording
        case .callEnded:
            state = .cooldown
        case .idle:
            break
        }
    }

    private func handle(_ event: TeamsCallStateMachine.Event) {
        switch event {
        case .callDetected(let snapshot):
            detectedApp = snapshot.teamsProcess?.displayName ?? "Microsoft Teams"
            print("[TeamsCallDetectorV5] Call detected: \(evidenceSummary)")
        case .startRecording(let snapshot):
            guard let process = snapshot.teamsProcess else { return }
            detectedApp = process.displayName
            onCallStarted?(StartContext(
                processID: process.pid,
                displayName: process.displayName,
                confidence: snapshot.confidenceScore
            ))
            print("[TeamsCallDetectorV5] Starting recording: \(evidenceSummary)")
        case .stopRecording(let reason):
            onCallEnded?()
            print("[TeamsCallDetectorV5] Stopping recording: \(reason)")
        case .returnToIdle:
            detectedApp = nil
            if state != .disabled {
                state = .monitoring
            }
        }
    }

    private func currentSnapshot() -> TeamsCallEvidenceSnapshot {
        let process = currentTeamsProcess()
        let genericAudio = isDefaultOutputRunning()
        let uiEvidence = process.map {
            TeamsCallUIEvidenceProvider.evidence(for: $0.pid)
        } ?? .none
        let teamsAudio = process.map {
            isProcessOutputRunning(pid: $0.pid)
        } ?? false

        return TeamsCallEvidenceSnapshot(
            observedAt: Date(),
            teamsProcess: process,
            teamsAudioActive: teamsAudio,
            genericOutputAudioActive: genericAudio,
            callControlEvidence: uiEvidence.callControlEvidence,
            callWindowTitleEvidence: uiEvidence.callWindowTitleEvidence,
            calendarArmed: false,
            explicitStart: false,
            explicitEnd: false
        )
    }

    private func currentTeamsProcess() -> TeamsProcessEvidence? {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return teamsBundleIDs.contains(bundleID)
        }

        let app = apps.first(where: \.isActive) ?? apps.first
        guard let app, let bundleID = app.bundleIdentifier else { return nil }

        return TeamsProcessEvidence(
            pid: app.processIdentifier,
            bundleIdentifier: bundleID,
            displayName: app.localizedName ?? "Microsoft Teams",
            frontmost: app.isActive
        )
    }

    private func isDefaultOutputRunning() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else { return false }

        var isRunning: UInt32 = 0
        propertyAddress.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        size = UInt32(MemoryLayout<UInt32>.size)
        let runStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &isRunning)
        return runStatus == noErr && isRunning != 0
    }

    private func isProcessOutputRunning(pid: pid_t) -> Bool {
        guard let processObjectID = audioProcessObjectID(for: pid) else { return false }
        if let isOutputRunning = boolAudioProperty(
            objectID: processObjectID,
            selector: kAudioProcessPropertyIsRunningOutput
        ) {
            return isOutputRunning
        }
        return boolAudioProperty(
            objectID: processObjectID,
            selector: kAudioProcessPropertyIsRunning
        ) ?? false
    }

    private func audioProcessObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var objectIDSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &processID,
            &objectIDSize,
            &objectID
        )
        guard status == noErr, objectID != kAudioObjectUnknown else { return nil }
        return objectID
    }

    private func boolAudioProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value != 0
    }

    private func summary(for snapshot: TeamsCallEvidenceSnapshot) -> String {
        var parts: [String] = []
        if let process = snapshot.teamsProcess {
            parts.append("Teams PID \(process.pid)")
            if process.frontmost {
                parts.append("frontmost")
            }
        } else {
            parts.append("Teams not running")
        }
        if snapshot.teamsAudioActive {
            parts.append("Teams output active")
        }
        if snapshot.callControlEvidence {
            parts.append("call controls visible")
        } else if snapshot.callWindowTitleEvidence {
            parts.append("meeting window title")
        }
        if snapshot.genericOutputAudioActive {
            parts.append("output audio active")
        }
        parts.append(String(format: "confidence %.2f", snapshot.confidenceScore))
        return parts.joined(separator: " · ")
    }
}
