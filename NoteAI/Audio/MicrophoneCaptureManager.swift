import AVFoundation

/// Captures audio from the system microphone for the local user's voice.
/// Automatically follows audio route changes (AirPods connect/disconnect, etc.)
/// so recording continues uninterrupted when the user switches devices.
final class MicrophoneCaptureManager {
    private var audioEngine: AVAudioEngine?
    private var onBufferCallback: ((AVAudioPCMBuffer) -> Void)?
    private var configObserver: NSObjectProtocol?

    func startCapture(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let hasPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !hasPermission {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    print("[MicCapture] Microphone access denied")
                }
            }
        }

        onBufferCallback = onBuffer

        let engine = AVAudioEngine()
        audioEngine = engine

        try installTapAndStart(engine: engine, onBuffer: onBuffer)

        // Listen for audio device changes (AirPods connect/disconnect, default device switch)
        // AVAudioEngine posts this when hardware config changes — we restart to follow the new device
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    func stopCapture() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        onBufferCallback = nil
    }

    private func installTapAndStart(engine: AVAudioEngine, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        print("[MicCapture] Mic format: \(format.sampleRate)Hz, \(format.channelCount)ch, \(format.commonFormat.rawValue)")

        // Use 4096-frame buffer (~85ms at 48kHz) — Core Audio delivers frequently,
        // the AudioBufferRing accumulates to 7s before sending to transcription.
        let bufferSize = AVAudioFrameCount(4096)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            onBuffer(buffer)
        }

        try engine.start()
        print("[MicCapture] Microphone capture started at \(format.sampleRate)Hz")
    }

    private func handleConfigurationChange() {
        guard let engine = audioEngine, let callback = onBufferCallback else { return }
        print("[MicCapture] Audio route changed — restarting mic capture for new device")

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

        do {
            try installTapAndStart(engine: engine, onBuffer: callback)
        } catch {
            print("[MicCapture] Failed to restart after device change: \(error)")
        }
    }
}
