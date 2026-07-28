import AVFoundation
import CoreGraphics
import Foundation

enum RecordingAudioSource: String, CaseIterable {
    case microphone
    case systemAudio
}

enum RecordingPermissionKind: String, CaseIterable {
    case microphone
    case screenRecording
    case processTap
}

enum RecordingPermissionStatus: Equatable {
    case unknown
    case granted
    case denied
    case unavailable(String)

    var isWarning: Bool {
        switch self {
        case .denied, .unavailable: return true
        case .unknown, .granted: return false
        }
    }
}

enum RecordingCaptureStatus: Equatable {
    case idle
    case capturing
    case unavailable(String)

    var isCapturing: Bool {
        if case .capturing = self { return true }
        return false
    }
}

struct RecordingAudioLevel: Equatable {
    var rms: Float = 0
    var updatedAt: Date = .distantPast

    var meterValue: Double {
        min(1, max(0, Double(rms) * 12))
    }
}

struct RecordingSourceDiagnostic: Equatable {
    var status: RecordingCaptureStatus = .idle
    var level = RecordingAudioLevel()
}

struct RecordingDiagnosticsSnapshot: Equatable {
    private static let systemAudioAccessConfirmedKey = "noteai.systemAudioAccessConfirmed"

    var microphone = RecordingSourceDiagnostic()
    var systemAudio = RecordingSourceDiagnostic()
    var permissions: [RecordingPermissionKind: RecordingPermissionStatus] = [
        .microphone: .unknown,
        .screenRecording: .unknown,
        .processTap: .unknown,
    ]
    var lastUpdatedAt = Date()

    var warnings: [String] {
        var result: [String] = []

        if permissions[.microphone] == .denied {
            result.append("Microphone permission is denied.")
        }
        if permissions[.screenRecording]?.isWarning == true {
            result.append("Screen Recording permission is unavailable.")
        }
        if case .unavailable(let reason) = permissions[.processTap], !systemAudio.status.isCapturing {
            result.append("Process tap access is unavailable: \(reason).")
        }
        if case .unavailable(let reason) = microphone.status {
            result.append("Microphone is not being captured: \(reason).")
        }
        if case .unavailable(let reason) = systemAudio.status {
            result.append("System audio is not being captured: \(reason).")
        }

        return result
    }

    mutating func updatePermission(_ kind: RecordingPermissionKind, status: RecordingPermissionStatus) {
        permissions[kind] = status
        lastUpdatedAt = Date()
    }

    mutating func updateCapture(_ source: RecordingAudioSource, status: RecordingCaptureStatus) {
        switch source {
        case .microphone:
            microphone.status = status
        case .systemAudio:
            systemAudio.status = status
        }
        lastUpdatedAt = Date()
    }

    mutating func updateLevel(_ source: RecordingAudioSource, rms: Float) {
        let level = RecordingAudioLevel(rms: rms, updatedAt: Date())
        switch source {
        case .microphone:
            microphone.level = level
        case .systemAudio:
            systemAudio.level = level
        }
        lastUpdatedAt = level.updatedAt
    }

    func troubleshootingLines() -> [String] {
        [
            "updatedAt=\(lastUpdatedAt)",
            "microphone.status=\(microphone.status.diagnosticDescription)",
            "microphone.rms=\(String(format: "%.5f", microphone.level.rms))",
            "systemAudio.status=\(systemAudio.status.diagnosticDescription)",
            "systemAudio.rms=\(String(format: "%.5f", systemAudio.level.rms))",
            "microphone.permission=\((permissions[.microphone] ?? .unknown).diagnosticDescription)",
            "screenRecording.permission=\((permissions[.screenRecording] ?? .unknown).diagnosticDescription)",
            "processTap.permission=\((permissions[.processTap] ?? .unknown).diagnosticDescription)",
        ]
    }

    static func currentPermissions() -> RecordingDiagnosticsSnapshot {
        var snapshot = RecordingDiagnosticsSnapshot()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            snapshot.updatePermission(.microphone, status: .granted)
        case .denied, .restricted:
            snapshot.updatePermission(.microphone, status: .denied)
        case .notDetermined:
            snapshot.updatePermission(.microphone, status: .unknown)
        @unknown default:
            snapshot.updatePermission(.microphone, status: .unavailable("Unknown authorization status"))
        }

        let hasScreenCaptureAccess = CGPreflightScreenCaptureAccess()
        let hasConfirmedSystemAudioAccess = UserDefaults.standard.bool(forKey: systemAudioAccessConfirmedKey)
        snapshot.updatePermission(
            .screenRecording,
            status: hasScreenCaptureAccess || hasConfirmedSystemAudioAccess ? .granted : .denied
        )

        if #available(macOS 14.2, *) {
            snapshot.updatePermission(.processTap, status: .unknown)
        } else {
            snapshot.updatePermission(.processTap, status: .unavailable("Requires macOS 14.2 or later"))
        }

        return snapshot
    }

    static func recordSystemAudioAccessConfirmed(_ confirmed: Bool) {
        UserDefaults.standard.set(confirmed, forKey: systemAudioAccessConfirmedKey)
    }
}

enum RecordingDiagnosticsPublicationPriority {
    case immediate
    case coalesced
}

enum RecordingDiagnosticsPublicationDirective: Equatable {
    case none
    case publish(RecordingDiagnosticsSnapshot)
    case schedule(after: TimeInterval)
}

/// Keeps high-frequency level metadata behind a small publication cadence
/// while allowing capture and permission state changes through immediately.
struct RecordingDiagnosticsPublicationPolicy {
    private let minimumInterval: TimeInterval
    private var lastPublicationTime: TimeInterval?
    private var pendingSnapshot: RecordingDiagnosticsSnapshot?
    private var hasScheduledFlush = false

    init(minimumInterval: TimeInterval = 0.25) {
        precondition(minimumInterval > 0)
        self.minimumInterval = minimumInterval
    }

    mutating func submit(
        _ snapshot: RecordingDiagnosticsSnapshot,
        priority: RecordingDiagnosticsPublicationPriority,
        at time: TimeInterval
    ) -> RecordingDiagnosticsPublicationDirective {
        if priority == .immediate {
            pendingSnapshot = nil
            lastPublicationTime = time
            return .publish(snapshot)
        }

        guard let lastPublicationTime else {
            self.lastPublicationTime = time
            return .publish(snapshot)
        }

        let remainingDelay = minimumInterval - (time - lastPublicationTime)
        guard remainingDelay > 0 else {
            pendingSnapshot = nil
            self.lastPublicationTime = time
            return .publish(snapshot)
        }

        pendingSnapshot = snapshot
        guard !hasScheduledFlush else { return .none }

        hasScheduledFlush = true
        return .schedule(after: remainingDelay)
    }

    mutating func flush(at time: TimeInterval) -> RecordingDiagnosticsPublicationDirective {
        hasScheduledFlush = false
        guard let pendingSnapshot else { return .none }

        if let lastPublicationTime {
            let remainingDelay = minimumInterval - (time - lastPublicationTime)
            if remainingDelay > 0 {
                hasScheduledFlush = true
                return .schedule(after: remainingDelay)
            }
        }

        self.pendingSnapshot = nil
        lastPublicationTime = time
        return .publish(pendingSnapshot)
    }
}

extension RecordingCaptureStatus {
    var diagnosticDescription: String {
        switch self {
        case .idle: return "idle"
        case .capturing: return "capturing"
        case .unavailable(let reason): return "unavailable(\(reason))"
        }
    }
}

extension RecordingPermissionStatus {
    var diagnosticDescription: String {
        switch self {
        case .unknown: return "unknown"
        case .granted: return "granted"
        case .denied: return "denied"
        case .unavailable(let reason): return "unavailable(\(reason))"
        }
    }
}
