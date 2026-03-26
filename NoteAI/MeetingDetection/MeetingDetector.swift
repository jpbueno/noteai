import AppKit
import Combine
import CoreAudio

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

    var onMeetingStarted: (() -> Void)?
    var onMeetingEnded: (() -> Void)?

    private var pollingTimer: Timer?
    private var silenceTimer: Timer?
    private var wasTeamsActive = false
    private var teamsAudioWasPlaying = false

    /// How often to check for meeting activity (seconds)
    private let pollInterval: TimeInterval = 3.0

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
        print("[MeetingDetector] Auto-detection stopped")
    }

    // MARK: - Detection Logic

    private func checkForMeeting() {
        let runningApps = NSWorkspace.shared.runningApplications

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
        var defaultDeviceID = AudioObjectID(kAudioObjectSystemObject)
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
