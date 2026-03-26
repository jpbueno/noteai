import AVFoundation
import ScreenCaptureKit

/// Fallback audio capture using ScreenCaptureKit for macOS 13+.
/// Captures audio from a specific app or all system audio.
final class ScreenCaptureProvider: NSObject {
    private var stream: SCStream?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func startCapture(for app: NSRunningApplication?, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        self.onBuffer = onBuffer

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let filter: SCContentFilter
        if let app,
           let scApp = content.applications.first(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            // Capture specific app's audio — include all windows of this app
            filter = SCContentFilter(display: content.displays[0], including: [scApp], exceptingWindows: [])
        } else {
            // Capture all audio from the default display
            guard let display = content.displays.first else {
                throw AudioCaptureError.screenCaptureNotAvailable
            }
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1

        // Minimize video overhead — we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        try await stream.startCapture()

        self.stream = stream
    }

    func stopCapture() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
        }
    }
}

extension ScreenCaptureProvider: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("ScreenCaptureKit stream stopped with error: \(error)")
    }
}

extension ScreenCaptureProvider: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        guard let format = AVAudioFormat(streamDescription: asbd) else { return }
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        var dataLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)

        if let dataPointer, let channelData = pcmBuffer.floatChannelData {
            let byteCount = Int(frameCount) * MemoryLayout<Float>.size
            memcpy(channelData[0], dataPointer, min(dataLength, byteCount))
        }

        onBuffer?(pcmBuffer)
    }
}
