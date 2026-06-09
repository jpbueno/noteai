import AVFoundation
import CoreAudio
import ScreenCaptureKit

struct CapturedAudioBuffer {
    let source: CapturedAudioSource
    let buffer: AVAudioPCMBuffer
}

enum CapturedAudioSource: Equatable {
    case microphone
    case systemAudio

    var fallbackSpeakerID: String {
        switch self {
        case .microphone:
            return TranscriptSpeakerLabels.localSpeakerID
        case .systemAudio:
            return TranscriptSpeakerLabels.remoteSpeakerID
        }
    }
}

enum AppAudioCaptureSource: Equatable {
    case processID(pid_t, displayName: String)
}

/// Orchestrates audio capture:
/// 1. ProcessTap (macOS 14.2+) for direct per-process audio capture from a meeting app
/// 2. ScreenCaptureKit ALL desktop audio capture as fallback (any app, any speaker)
/// 3. Microphone capture for the local user's voice
///
/// All audio is resampled to 16kHz mono before being delivered to the transcription engine.
final class AudioCaptureManager: NSObject {
    var onAudioBuffer: ((CapturedAudioBuffer) -> Void)?
    var onDiagnosticsChange: ((RecordingDiagnosticsSnapshot) -> Void)?

    private var processTap: Any?  // ProcessTapProvider (macOS 14.2+)
    private var scStream: SCStream?
    private var scDelegate: AudioStreamDelegate?
    private var microphoneCapture: MicrophoneCaptureManager?

    private let appAudioRing = AudioBufferRing(capacity: 60)
    private let micAudioRing = AudioBufferRing(capacity: 60)
    private var diagnostics = RecordingDiagnosticsSnapshot.currentPermissions()
    private let diagnosticsLock = NSLock()

    private func log(_ msg: String) {
        let logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NoteAI")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("audio_capture.log")
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: logFile)
            }
        }
    }
    private var isCapturing = false

    /// Cached converters keyed by the full source format to avoid reusing a converter
    /// across Bluetooth route changes that keep the same sample rate but change layout.
    private var converterCache: [AudioConverterCacheKey: AVAudioConverter] = [:]

    /// Target format for WhisperKit: 16kHz, mono, float32
    private static let targetSampleRate: Double = 16000
    private static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    func startCapture(preferredSource: AppAudioCaptureSource? = nil) async throws {
        guard !isCapturing else { return }
        updateDiagnostics { snapshot in
            snapshot = RecordingDiagnosticsSnapshot.currentPermissions()
            snapshot.updateCapture(.microphone, status: .idle)
            snapshot.updateCapture(.systemAudio, status: .idle)
        }

        // Try to capture meeting app audio
        let appCaptureStarted = await startAppAudioCapture(preferredSource: preferredSource)
        if !appCaptureStarted {
            log("WARNING: No app audio — mic only (meeting participants won't be transcribed)")
            print("[AudioCapture] No app audio capture available — mic only mode")
        }

        // Always start microphone — captures the local user's voice
        let hasMicAccess = await MicrophoneCaptureManager.requestAccessIfNeeded()
        updateDiagnostics { snapshot in
            snapshot.updatePermission(.microphone, status: hasMicAccess ? .granted : .denied)
        }
        guard hasMicAccess else {
            updateDiagnostics { snapshot in
                snapshot.updateCapture(.microphone, status: .unavailable("Permission denied"))
            }
            writeDiagnosticsLog("Microphone unavailable")
            throw AudioCaptureError.microphoneAccessDenied
        }

        let mic = MicrophoneCaptureManager()
        do {
            try mic.startCapture { [weak self] buffer in
                self?.handleMicBuffer(buffer)
            }
        } catch {
            updateDiagnostics { snapshot in
                snapshot.updateCapture(.microphone, status: .unavailable(error.localizedDescription))
            }
            writeDiagnosticsLog("Microphone start failed")
            throw error
        }
        microphoneCapture = mic
        isCapturing = true
        updateDiagnostics { snapshot in
            snapshot.updateCapture(.microphone, status: .capturing)
        }
        log("Capture started: mic=true appAudio=\(appCaptureStarted)")
        writeDiagnosticsLog("Capture started")
        print("[AudioCapture] Capture started (mic + \(appCaptureStarted ? "app audio" : "no app audio"))")
    }

    func stopCapture() {
        if #available(macOS 14.2, *), let tap = processTap as? ProcessTapProvider {
            tap.stopTap()
            processTap = nil
        }

        if let stream = scStream {
            stream.stopCapture { _ in }
            scStream = nil
            scDelegate = nil
        }

        microphoneCapture?.stopCapture()
        microphoneCapture = nil

        appAudioRing.clear()
        micAudioRing.clear()
        converterCache.removeAll()
        isCapturing = false
        updateDiagnostics { snapshot in
            snapshot.updateCapture(.microphone, status: .idle)
            snapshot.updateCapture(.systemAudio, status: .idle)
        }
        writeDiagnosticsLog("Capture stopped")
        print("[AudioCapture] Capture stopped")
    }

    // MARK: - App audio capture (Teams/browser)

    private func startAppAudioCapture(preferredSource: AppAudioCaptureSource? = nil) async -> Bool {
        // ScreenCaptureKit needs screen capture access, but Core Audio process taps
        // use the system-audio permission added in macOS 14.2. Try taps first so
        // audio-only grants are not blocked by a screen preflight failure.
        let hasScreenPermission = CGPreflightScreenCaptureAccess()
        updateDiagnostics { snapshot in
            snapshot.updatePermission(.screenRecording, status: hasScreenPermission ? .granted : .denied)
        }

        // Strategy 1: ProcessTap (macOS 14.2+) — direct per-PID capture, best quality
        if #available(macOS 14.2, *) {
            if let preferredSource {
                do {
                    let tap = ProcessTapProvider()
                    let sourceDescription = preferredSource.displayName
                    try tap.startTap(processID: preferredSource.processID) { [weak self] buffer in
                        self?.handleAppAudioBuffer(buffer)
                    }
                    processTap = tap
                    RecordingDiagnosticsSnapshot.recordSystemAudioAccessConfirmed(true)
                    updateDiagnostics { snapshot in
                        snapshot.updatePermission(.screenRecording, status: .granted)
                        snapshot.updatePermission(.processTap, status: .granted)
                        snapshot.updateCapture(.systemAudio, status: .capturing)
                    }
                    log("ProcessTap OK: PID=\(preferredSource.processID) app=\(sourceDescription)")
                    print("[AudioCapture] ProcessTap capturing PID \(preferredSource.processID) (\(sourceDescription))")
                    return true
                } catch {
                    RecordingDiagnosticsSnapshot.recordSystemAudioAccessConfirmed(false)
                    updateDiagnostics { snapshot in
                        snapshot.updatePermission(.processTap, status: .unavailable(error.localizedDescription))
                    }
                    log("Preferred ProcessTap FAILED: \(error)")
                    print("[AudioCapture] Preferred ProcessTap failed: \(error) — trying detected app/fallback")
                }
            }

            if let app = ProcessMonitor.findMeetingApp() {
                do {
                    let tap = ProcessTapProvider()
                    try tap.startTap(processID: app.processIdentifier) { [weak self] buffer in
                        self?.handleAppAudioBuffer(buffer)
                    }
                    processTap = tap
                    RecordingDiagnosticsSnapshot.recordSystemAudioAccessConfirmed(true)
                    updateDiagnostics { snapshot in
                        snapshot.updatePermission(.screenRecording, status: .granted)
                        snapshot.updatePermission(.processTap, status: .granted)
                        snapshot.updateCapture(.systemAudio, status: .capturing)
                    }
                    log("ProcessTap OK: PID=\(app.processIdentifier) app=\(app.localizedName ?? "unknown")")
                    print("[AudioCapture] ProcessTap capturing PID \(app.processIdentifier) (\(app.localizedName ?? "unknown"))")
                    return true
                } catch {
                    RecordingDiagnosticsSnapshot.recordSystemAudioAccessConfirmed(false)
                    updateDiagnostics { snapshot in
                        snapshot.updatePermission(.processTap, status: .unavailable(error.localizedDescription))
                    }
                    log("ProcessTap FAILED: \(error)")
                    print("[AudioCapture] ProcessTap failed: \(error) — trying ScreenCaptureKit")
                }
            } else {
                updateDiagnostics { snapshot in
                    snapshot.updatePermission(.processTap, status: .unavailable("No supported meeting app is running"))
                }
            }
        }

        guard hasScreenPermission else {
            log("No Screen Recording permission — ScreenCaptureKit fallback disabled; mic-only mode")
            updateDiagnostics { snapshot in
                snapshot.updateCapture(.systemAudio, status: .unavailable("Screen & System Audio Recording permission is not available"))
                if snapshot.permissions[.processTap] == .unknown {
                    snapshot.updatePermission(.processTap, status: .unavailable("No supported meeting app is running"))
                }
            }
            print("[AudioCapture] No Screen Recording permission for SCK fallback — mic only")
            return false
        }

        // Strategy 2: ScreenCaptureKit — capture ALL desktop audio
        // Not limited to a specific meeting app — captures any audio output
        // so it works regardless of which app is producing sound
        do {
            try await startSCKDesktopAudioCapture()
            RecordingDiagnosticsSnapshot.recordSystemAudioAccessConfirmed(true)
            updateDiagnostics { snapshot in
                snapshot.updatePermission(.screenRecording, status: .granted)
                snapshot.updateCapture(.systemAudio, status: .capturing)
            }
            log("ScreenCaptureKit desktop audio OK")
            print("[AudioCapture] ScreenCaptureKit capturing all desktop audio")
            return true
        } catch {
            updateDiagnostics { snapshot in
                snapshot.updateCapture(.systemAudio, status: .unavailable(error.localizedDescription))
            }
            log("ScreenCaptureKit desktop audio FAILED: \(error)")
            print("[AudioCapture] SCK desktop audio failed: \(error)")
        }

        return false
    }

    private func startSCKDesktopAudioCapture() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw AudioCaptureError.screenCaptureNotAvailable
        }

        // Exclude our own app to avoid feedback loops
        let selfApp = content.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let excludeApps = selfApp.map { [$0] } ?? []

        let filter = SCContentFilter(display: display, excludingApplications: excludeApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true

        let delegate = AudioStreamDelegate { [weak self] buffer in
            self?.handleAppAudioBuffer(buffer)
        }
        scDelegate = delegate

        let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        scStream = stream
    }

    // MARK: - Audio handling with resampling

    private func handleAppAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let resampled = resampleTo16kMono(buffer)
        updateDiagnostics { snapshot in
            snapshot.updateLevel(.systemAudio, rms: rms(resampled))
        }
        appAudioRing.append(resampled)
        if let merged = appAudioRing.mergeIfReady(targetDuration: 7.0) {
            print("[AudioCapture] App audio chunk: \(merged.frameLength) frames, RMS=\(rms(merged))")
            onAudioBuffer?(CapturedAudioBuffer(source: .systemAudio, buffer: merged))
        }
    }

    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        let resampled = resampleTo16kMono(buffer)
        updateDiagnostics { snapshot in
            snapshot.updateLevel(.microphone, rms: rms(resampled))
        }
        micAudioRing.append(resampled)
        if let merged = micAudioRing.mergeIfReady(targetDuration: 7.0) {
            print("[AudioCapture] Mic audio chunk: \(merged.frameLength) frames, RMS=\(rms(merged))")
            onAudioBuffer?(CapturedAudioBuffer(source: .microphone, buffer: merged))
        }
    }

    /// Resample any audio buffer to 16kHz mono float32 for WhisperKit.
    /// Caches the AVAudioConverter per source sample rate to avoid creating one per buffer.
    private func resampleTo16kMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let srcFormat = buffer.format

        // Already in target format — pass through
        if srcFormat.sampleRate == Self.targetSampleRate &&
           srcFormat.channelCount == 1 &&
           srcFormat.commonFormat == .pcmFormatFloat32 {
            return buffer
        }

        // Reuse cached converter for this exact source format.
        let cacheKey = AudioConverterCacheKey(format: srcFormat)
        let converter: AVAudioConverter
        if let cached = converterCache[cacheKey] {
            converter = cached
        } else {
            guard let newConverter = AVAudioConverter(from: srcFormat, to: Self.targetFormat) else {
                print("[AudioCapture] Failed to create converter from \(srcFormat) to 16kHz mono")
                return buffer
            }
            converterCache[cacheKey] = newConverter
            converter = newConverter
        }

        let ratio = Self.targetSampleRate / srcFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: outputFrameCount) else {
            return buffer
        }

        converter.reset()
        var error: NSError?
        var isDone = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            print("[AudioCapture] Resample error: \(error)")
            return buffer
        }

        return outputBuffer
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let s = data[0][i]
            sum += s * s
        }
        return sqrt(sum / Float(count))
    }

    private func updateDiagnostics(_ update: (inout RecordingDiagnosticsSnapshot) -> Void) {
        diagnosticsLock.lock()
        update(&diagnostics)
        let snapshot = diagnostics
        diagnosticsLock.unlock()
        onDiagnosticsChange?(snapshot)
    }

    private func writeDiagnosticsLog(_ event: String) {
        diagnosticsLock.lock()
        let snapshot = diagnostics
        diagnosticsLock.unlock()
        log("Diagnostics \(event): \(snapshot.troubleshootingLines().joined(separator: " | "))")
    }
}

struct AudioConverterCacheKey: Hashable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    let commonFormat: AVAudioCommonFormat
    let interleaved: Bool

    init(format: AVAudioFormat) {
        self.sampleRate = format.sampleRate
        self.channelCount = format.channelCount
        self.commonFormat = format.commonFormat
        self.interleaved = format.isInterleaved
    }
}

private extension AppAudioCaptureSource {
    var processID: pid_t {
        switch self {
        case .processID(let pid, _):
            return pid
        }
    }

    var displayName: String {
        switch self {
        case .processID(_, let displayName):
            return displayName
        }
    }
}

// MARK: - SCStream delegate for audio capture

private class AudioStreamDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }

        guard let avFormat = AVAudioFormat(streamDescription: asbd),
              let blockBuffer = sampleBuffer.dataBuffer else {
            return
        }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount) else {
            return
        }
        pcmBuffer.frameLength = frameCount

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)

        guard status == noErr, let srcData = dataPointer else { return }

        if let channelData = pcmBuffer.floatChannelData {
            let bytesPerFrame = Int(avFormat.streamDescription.pointee.mBytesPerFrame)
            let channelCount = Int(avFormat.channelCount)

            if channelCount == 1 {
                memcpy(channelData[0], srcData, min(dataLength, Int(frameCount) * bytesPerFrame))
            } else {
                let srcFloats = UnsafeRawPointer(srcData).bindMemory(to: Float.self, capacity: Int(frameCount) * channelCount)
                for frame in 0..<Int(frameCount) {
                    for ch in 0..<channelCount {
                        channelData[ch][frame] = srcFloats[frame * channelCount + ch]
                    }
                }
            }
        }

        onBuffer(pcmBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioCapture] SCStream stopped with error: \(error)")
    }
}
