import AVFoundation

/// Captures audio from the system microphone for the local user's voice.
final class MicrophoneCaptureManager {
    private var audioEngine: AVAudioEngine?

    func startCapture(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let hasPermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !hasPermission {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                if !granted {
                    print("[MicCapture] Microphone access denied")
                }
            }
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        print("[MicCapture] Mic format: \(format.sampleRate)Hz, \(format.channelCount)ch, \(format.commonFormat.rawValue)")

        // Use 4096-frame buffer (~85ms at 48kHz) — Core Audio delivers frequently,
        // the AudioBufferRing accumulates to 5s before sending to transcription.
        let bufferSize = AVAudioFrameCount(4096)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            onBuffer(buffer)
        }

        try engine.start()
        audioEngine = engine
        print("[MicCapture] Microphone capture started at \(format.sampleRate)Hz")
    }

    func stopCapture() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }
}
