import AVFoundation

/// Thread-safe ring buffer that accumulates audio chunks and merges them
/// when a target duration is reached.
final class AudioBufferRing: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.noteai.bufferring")
    private var buffers: [AVAudioPCMBuffer] = []
    private var accumulatedDuration: TimeInterval = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.sync {
            buffers.append(buffer)
            let duration = Double(buffer.frameLength) / buffer.format.sampleRate
            accumulatedDuration += duration

            // Keep only the last `capacity` seconds worth of buffers
            while accumulatedDuration > Double(capacity), buffers.count > 1 {
                let removed = buffers.removeFirst()
                let removedDuration = Double(removed.frameLength) / removed.format.sampleRate
                accumulatedDuration -= removedDuration
            }
        }
    }

    func mergeIfReady(targetDuration: TimeInterval) -> AVAudioPCMBuffer? {
        queue.sync {
            guard accumulatedDuration >= targetDuration, let format = buffers.first?.format else {
                return nil
            }

            let totalFrames = buffers.reduce(0) { $0 + $1.frameLength }
            guard let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
                return nil
            }

            var offset: AVAudioFrameCount = 0
            for buffer in buffers {
                guard let srcData = buffer.floatChannelData,
                      let dstData = merged.floatChannelData else { continue }

                for channel in 0..<Int(format.channelCount) {
                    let src = srcData[channel]
                    let dst = dstData[channel].advanced(by: Int(offset))
                    dst.update(from: src, count: Int(buffer.frameLength))
                }
                offset += buffer.frameLength
            }
            merged.frameLength = offset

            // Clear consumed buffers
            buffers.removeAll()
            accumulatedDuration = 0

            return merged
        }
    }

    func clear() {
        queue.sync {
            buffers.removeAll()
            accumulatedDuration = 0
        }
    }
}
