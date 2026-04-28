import AppKit
import AVFoundation
import CoreGraphics
import Foundation

final class LocalCaptureHelperStatusProvider {
    private let helperVersion: String

    init(helperVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0") {
        self.helperVersion = helperVersion
    }

    func health() -> LocalCaptureHelperHealthResponse {
        LocalCaptureHelperHealthResponse(
            protocolVersion: LocalCaptureHelperProtocol.version,
            helperVersion: helperVersion,
            appName: "NoteAI Capture Helper",
            status: "ready",
            pairingRequired: true,
            capabilities: LocalCaptureHelperCapabilities(
                status: true,
                pairing: true,
                captureControl: false,
                events: false,
                audioStreaming: false
            )
        )
    }

    func status() async -> LocalCaptureHelperStatusResponse {
        await MainActor.run {
            let permissions = currentPermissions()
            let teams = currentTeamsStatus()
            let diagnostics = diagnosticMessages(permissions: permissions, teams: teams)
            return LocalCaptureHelperStatusResponse(
                protocolVersion: LocalCaptureHelperProtocol.version,
                helperVersion: helperVersion,
                captureState: "idle",
                recordingIndicator: "visible-idle",
                permissions: permissions,
                teams: teams,
                sources: sourceStatus(permissions: permissions),
                diagnostics: diagnostics
            )
        }
    }

    @MainActor
    private func currentPermissions() -> LocalCaptureHelperPermissions {
        LocalCaptureHelperPermissions(
            microphone: microphonePermission(),
            screenRecording: screenRecordingPermission(),
            processTap: processTapPermission()
        )
    }

    @MainActor
    private func microphonePermission() -> LocalCaptureHelperPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return LocalCaptureHelperPermission(status: "granted", action: nil, reason: nil, requiresMacOS: nil)
        case .denied, .restricted:
            return LocalCaptureHelperPermission(status: "denied", action: "open-system-settings", reason: nil, requiresMacOS: nil)
        case .notDetermined:
            return LocalCaptureHelperPermission(status: "unknown", action: "request-permission", reason: nil, requiresMacOS: nil)
        @unknown default:
            return LocalCaptureHelperPermission(status: "unavailable", action: nil, reason: "Unknown microphone authorization status", requiresMacOS: nil)
        }
    }

    @MainActor
    private func screenRecordingPermission() -> LocalCaptureHelperPermission {
        if CGPreflightScreenCaptureAccess() {
            return LocalCaptureHelperPermission(status: "granted", action: nil, reason: nil, requiresMacOS: nil)
        }
        return LocalCaptureHelperPermission(status: "denied", action: "open-system-settings", reason: nil, requiresMacOS: nil)
    }

    @MainActor
    private func processTapPermission() -> LocalCaptureHelperPermission {
        if #available(macOS 14.2, *) {
            return LocalCaptureHelperPermission(status: "available", action: nil, reason: nil, requiresMacOS: "14.2")
        }
        return LocalCaptureHelperPermission(
            status: "unavailable",
            action: nil,
            reason: "ProcessTap requires macOS 14.2 or later.",
            requiresMacOS: "14.2"
        )
    }

    @MainActor
    private func currentTeamsStatus() -> LocalCaptureHelperTeamsStatus {
        let teamsBundleIDs: Set<String> = ["com.microsoft.teams", "com.microsoft.teams2"]
        let teamsApp = NSWorkspace.shared.runningApplications.first { app in
            guard let bundleIdentifier = app.bundleIdentifier else { return false }
            return teamsBundleIDs.contains(bundleIdentifier)
        }

        guard let teamsApp else {
            return LocalCaptureHelperTeamsStatus(
                detected: false,
                bundleId: nil,
                pid: nil,
                displayName: nil,
                frontmost: false,
                audioActivity: "unknown"
            )
        }

        return LocalCaptureHelperTeamsStatus(
            detected: true,
            bundleId: teamsApp.bundleIdentifier,
            pid: Int(teamsApp.processIdentifier),
            displayName: teamsApp.localizedName ?? "Microsoft Teams",
            frontmost: teamsApp.isActive,
            audioActivity: "unknown"
        )
    }

    private func sourceStatus(permissions: LocalCaptureHelperPermissions) -> LocalCaptureHelperSources {
        let micStatus = permissions.microphone.status == "granted" ? "available" : "blocked"
        let screenGranted = permissions.screenRecording.status == "granted"
        return LocalCaptureHelperSources(
            microphone: LocalCaptureHelperSourceStatus(
                status: micStatus,
                adapter: "microphone",
                level: 0,
                reason: micStatus == "available" ? nil : "Microphone permission is not granted."
            ),
            teamsAudio: LocalCaptureHelperSourceStatus(
                status: "notProbed",
                adapter: "processTap",
                level: 0,
                reason: "Audio levels are available only during an explicit test or active recording."
            ),
            desktopAudioFallback: LocalCaptureHelperSourceStatus(
                status: screenGranted ? "available" : "blocked",
                adapter: "screenCaptureKit",
                level: 0,
                reason: screenGranted ? nil : "Screen Recording permission is denied."
            )
        )
    }

    private func diagnosticMessages(
        permissions: LocalCaptureHelperPermissions,
        teams: LocalCaptureHelperTeamsStatus
    ) -> [LocalCaptureHelperDiagnostic] {
        var diagnostics: [LocalCaptureHelperDiagnostic] = []
        if permissions.microphone.status == "denied" {
            diagnostics.append(LocalCaptureHelperDiagnostic(
                severity: "warning",
                code: "microphone-denied",
                message: "Grant Microphone access to capture your side of the meeting."
            ))
        }
        if permissions.screenRecording.status == "denied" {
            diagnostics.append(LocalCaptureHelperDiagnostic(
                severity: "warning",
                code: "screen-recording-denied",
                message: "Grant Screen Recording to capture Teams desktop audio."
            ))
        }
        if !teams.detected {
            diagnostics.append(LocalCaptureHelperDiagnostic(
                severity: "info",
                code: "teams-not-running",
                message: "Microsoft Teams is not running."
            ))
        }
        return diagnostics
    }
}
