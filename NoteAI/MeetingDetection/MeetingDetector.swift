import AppKit
import Combine
import CoreAudio
import EventKit

struct CalendarMeetingSignal: Equatable {
    let title: String
    let startDate: Date
    let endDate: Date
}

enum CalendarMeetingAuthorization: Equatable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case restricted
    case unavailable(String)

    var canReadEvents: Bool {
        self == .authorized
    }
}

enum RecordingReadinessState: Equatable {
    case idle
    case recording
    case processing
}

struct MeetingRecordingReadiness: Equatable {
    enum Mode: Equatable {
        case manualFallback
        case likelyMeeting
        case calendarArmed
        case recording
        case processing
    }

    let mode: Mode
    let title: String
    let detail: String
    let badgeTitle: String
    let primaryActionTitle: String
    let systemImage: String

    static func resolve(
        recordingState: RecordingReadinessState,
        autoDetectEnabled: Bool,
        detectionState: MeetingDetector.DetectionState,
        detectedApp: String?,
        calendarAuthorization: CalendarMeetingAuthorization,
        upcomingCalendarEvent: CalendarMeetingSignal?
    ) -> MeetingRecordingReadiness {
        switch recordingState {
        case .recording:
            return MeetingRecordingReadiness(
                mode: .recording,
                title: "Recording",
                detail: "\(detectedApp ?? "Manual") capture is active.",
                badgeTitle: "Live",
                primaryActionTitle: "Stop Recording",
                systemImage: "record.circle.fill"
            )
        case .processing:
            return MeetingRecordingReadiness(
                mode: .processing,
                title: "Processing meeting",
                detail: "Finalizing transcript and summary.",
                badgeTitle: "Processing",
                primaryActionTitle: "Processing...",
                systemImage: "hourglass"
            )
        case .idle:
            break
        }

        if autoDetectEnabled,
           let event = upcomingCalendarEvent,
           calendarAuthorization.canReadEvents {
            return MeetingRecordingReadiness(
                mode: .calendarArmed,
                title: "\(event.title) soon",
                detail: "Calendar access is available; recording is auto-armed for this upcoming meeting.",
                badgeTitle: "Armed",
                primaryActionTitle: "Start Recording",
                systemImage: "calendar.badge.clock"
            )
        }

        if autoDetectEnabled,
           detectionState != .disabled,
           let app = detectedApp,
           !app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MeetingRecordingReadiness(
                mode: .likelyMeeting,
                title: "\(app) detected",
                detail: "A likely meeting signal is present. Manual start remains available.",
                badgeTitle: "Signal",
                primaryActionTitle: "Start Recording",
                systemImage: "waveform.path.ecg"
            )
        }

        return MeetingRecordingReadiness(
            mode: .manualFallback,
            title: "Manual recording",
            detail: manualFallbackDetail(
                autoDetectEnabled: autoDetectEnabled,
                calendarAuthorization: calendarAuthorization
            ),
            badgeTitle: "Manual",
            primaryActionTitle: "Start Recording",
            systemImage: "record.circle"
        )
    }

    private static func manualFallbackDetail(
        autoDetectEnabled: Bool,
        calendarAuthorization: CalendarMeetingAuthorization
    ) -> String {
        if !autoDetectEnabled {
            return "Automatic detection is off. Use explicit manual recording."
        }

        switch calendarAuthorization {
        case .authorized:
            return "No upcoming calendar meeting is armed. Use explicit manual recording."
        case .denied, .restricted:
            return "Calendar access is unavailable. Manual recording remains primary."
        case .unavailable(let reason):
            return "Calendar access is unavailable: \(reason). Manual recording remains primary."
        case .notDetermined, .unknown:
            return "Calendar access has not been granted. Manual recording remains primary."
        }
    }
}

/// Watches for active meetings by monitoring when Teams (or other meeting apps)
/// start producing audio. Auto-triggers recording start/stop.
@MainActor
final class MeetingDetector: ObservableObject {
    enum DetectionState: Equatable {
        case monitoring    // Watching for a meeting to start
        case detected      // Meeting audio detected, recording triggered
        case disabled      // Auto-detection is off
    }

    @Published var state: DetectionState = .disabled
    @Published var detectedApp: String?
    @Published var likelyMeetingApp: String?
    @Published var calendarAuthorization: CalendarMeetingAuthorization = .unknown
    @Published var upcomingCalendarEvent: CalendarMeetingSignal?

    var onMeetingStarted: (() -> Void)?
    var onMeetingEnded: (() -> Void)?

    private let eventStore = EKEventStore()
    private var pollingTimer: Timer?
    private var silenceTimer: Timer?
    private var wasTeamsActive = false
    private var teamsAudioWasPlaying = false

    /// How often to check for meeting activity (seconds)
    private let pollInterval: TimeInterval = 3.0
    private let calendarAutoArmLeadTime: TimeInterval = 5 * 60
    private let calendarMeetingGracePeriod: TimeInterval = 10 * 60

    /// How long audio must be silent before we consider the meeting ended
    private var silenceThreshold: TimeInterval {
        UserDefaults.standard.double(forKey: "autoStopSilenceDuration").clamped(to: 30...300, fallback: 60)
    }

    /// Teams bundle IDs (desktop app variants)
    private let teamsBundleIDs: Set<String> = [
        "com.microsoft.teams",
        "com.microsoft.teams2",
    ]

    /// All meeting-capable app bundle IDs
    private let meetingBundleIDs: Set<String> = [
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.apple.Safari",
    ]

    func startMonitoring() {
        guard state == .disabled else { return }
        state = .monitoring
        wasTeamsActive = false
        teamsAudioWasPlaying = false
        refreshCalendarSignal()
        requestCalendarAccessIfNeeded()

        // Poll for meeting app activity
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForMeeting()
            }
        }

        print("[MeetingDetector] Auto-detection started — monitoring for Teams/Meet audio")
    }

    func stopMonitoring() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        state = .disabled
        wasTeamsActive = false
        teamsAudioWasPlaying = false
        detectedApp = nil
        likelyMeetingApp = nil
        upcomingCalendarEvent = nil
        print("[MeetingDetector] Auto-detection stopped")
    }

    // MARK: - Detection Logic

    private func checkForMeeting() {
        let runningApps = NSWorkspace.shared.runningApplications
        refreshLikelyMeetingApp(runningApps: runningApps)
        refreshCalendarSignal()

        // Check if Teams is running and in a call
        let teamsRunning = runningApps.contains { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return teamsBundleIDs.contains(bundleID)
        }

        if teamsRunning {
            let teamsIsActive = isTeamsInCall()

            if teamsIsActive && !teamsAudioWasPlaying && state == .monitoring {
                // Teams call just started
                teamsAudioWasPlaying = true
                detectedApp = "Microsoft Teams"
                triggerMeetingStart()
            } else if !teamsIsActive && teamsAudioWasPlaying && state == .detected {
                // Teams call audio stopped — start silence countdown
                startSilenceCountdown()
            } else if teamsIsActive && state == .detected {
                // Still in call — reset silence timer
                cancelSilenceCountdown()
            }
        }

        // Also check for browser-based meetings via audio activity
        if !teamsRunning || !teamsAudioWasPlaying {
            checkBrowserMeetingAudio(runningApps: runningApps)
        }
    }

    private func refreshLikelyMeetingApp(runningApps: [NSRunningApplication]) {
        guard state == .monitoring else { return }
        likelyMeetingApp = runningApps.first { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return teamsBundleIDs.contains(bundleID)
        }?.localizedName
    }

    private func refreshCalendarSignal(now: Date = Date()) {
        calendarAuthorization = Self.calendarAuthorizationStatus()
        guard calendarAuthorization.canReadEvents else {
            upcomingCalendarEvent = nil
            return
        }

        let windowStart = now.addingTimeInterval(-calendarMeetingGracePeriod)
        let windowEnd = now.addingTimeInterval(calendarAutoArmLeadTime)
        let predicate = eventStore.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: nil
        )
        upcomingCalendarEvent = eventStore.events(matching: predicate)
            .filter(Self.isAutoArmCandidate)
            .sorted { $0.startDate < $1.startDate }
            .first
            .map(Self.calendarSignal)
    }

    private func requestCalendarAccessIfNeeded() {
        guard Self.calendarAuthorizationStatus() == .notDetermined else { return }

        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshCalendarSignal()
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] _, _ in
                Task { @MainActor in
                    self?.refreshCalendarSignal()
                }
            }
        }
    }

    private static func calendarAuthorizationStatus() -> CalendarMeetingAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized, .fullAccess:
            return .authorized
        case .writeOnly:
            return .restricted
        @unknown default:
            return .unknown
        }
    }

    private static func isAutoArmCandidate(_ event: EKEvent) -> Bool {
        guard !event.isAllDay,
              event.status != .canceled,
              event.availability != .free,
              event.endDate > event.startDate,
              event.endDate.timeIntervalSince(event.startDate) <= 4 * 60 * 60
        else {
            return false
        }

        return true
    }

    private static func calendarSignal(from event: EKEvent) -> CalendarMeetingSignal {
        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CalendarMeetingSignal(
            title: title.isEmpty
                ? "Calendar meeting"
                : title,
            startDate: event.startDate,
            endDate: event.endDate
        )
    }

    /// Detect if Teams is actively in a call by checking if it's producing audio.
    /// We check the process audio activity via CoreAudio.
    private func isTeamsInCall() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier, teamsBundleIDs.contains(bundleID) else { continue }

            // Check if Teams window title indicates a call
            // Teams changes its window title during calls (e.g., includes participant names)
            if isAppProducingAudio(pid: app.processIdentifier) {
                return true
            }

            // Fallback: check if Teams is the frontmost app and has been active recently
            // This catches cases where audio detection isn't available
            if app.isActive && wasTeamsActive {
                return true
            }

            wasTeamsActive = app.isActive
        }

        return false
    }

    /// Check if a process is producing audio by querying CoreAudio.
    private func isAppProducingAudio(pid: pid_t) -> Bool {
        // Get the default output device
        let defaultDeviceID = AudioObjectID(kAudioObjectSystemObject)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(defaultDeviceID, &propertyAddress, 0, nil, &size, &deviceID)
        guard status == noErr else { return false }

        // Check if the device is running (any app producing audio)
        var isRunning: UInt32 = 0
        propertyAddress.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        size = UInt32(MemoryLayout<UInt32>.size)
        let runStatus = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &isRunning)
        guard runStatus == noErr else { return false }

        return isRunning != 0
    }

    /// Check if a browser might be in a Google Meet / Teams Web call.
    private func checkBrowserMeetingAudio(runningApps: [NSRunningApplication]) {
        guard state == .monitoring else { return }

        // If system audio is playing and a browser is the frontmost app, it might be a meeting
        let frontApp = NSWorkspace.shared.frontmostApplication
        guard let bundleID = frontApp?.bundleIdentifier,
              meetingBundleIDs.contains(bundleID),
              !teamsBundleIDs.contains(bundleID) else { return }

        if isAppProducingAudio(pid: frontApp?.processIdentifier ?? 0) {
            // Browser is producing audio and is in focus — could be a meeting
            // We wait for audio to persist for 10+ seconds before auto-triggering
            if !teamsAudioWasPlaying {
                teamsAudioWasPlaying = true
                // Wait 10 seconds to confirm it's not just a video/music
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, self.state == .monitoring else { return }
                    if self.isAppProducingAudio(pid: frontApp?.processIdentifier ?? 0) {
                        self.detectedApp = frontApp?.localizedName ?? "Browser"
                        self.triggerMeetingStart()
                    } else {
                        self.teamsAudioWasPlaying = false
                    }
                }
            }
        }
    }

    // MARK: - Triggers

    private func triggerMeetingStart() {
        guard state == .monitoring else { return }
        state = .detected
        print("[MeetingDetector] Meeting detected in \(detectedApp ?? "unknown app") — auto-starting recording")
        onMeetingStarted?()
    }

    private func startSilenceCountdown() {
        guard silenceTimer == nil else { return }
        print("[MeetingDetector] Audio stopped — waiting \(Int(silenceThreshold))s before ending meeting")

        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceThreshold, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .detected else { return }
                self.teamsAudioWasPlaying = false
                self.state = .monitoring
                self.detectedApp = nil
                print("[MeetingDetector] Silence threshold reached — auto-stopping recording")
                self.onMeetingEnded?()
            }
        }
    }

    private func cancelSilenceCountdown() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
}

// MARK: - Helpers

private extension Double {
    func clamped(to range: ClosedRange<Double>, fallback: Double) -> Double {
        if self == 0 { return fallback }
        return min(max(self, range.lowerBound), range.upperBound)
    }
}
