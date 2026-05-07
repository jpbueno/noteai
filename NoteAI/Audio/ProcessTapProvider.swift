import AVFoundation
import CoreAudio

/// Wraps `AudioHardwareCreateProcessTap` to capture audio from a specific app process.
/// Available on macOS 14.2+.
@available(macOS 14.2, *)
final class ProcessTapProvider {
    private var tapID: AudioObjectID = .init()
    private var aggregateDeviceID: AudioObjectID = .init()
    private var audioEngine: AVAudioEngine?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func startTap(processID: pid_t, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.onBuffer = onBuffer

        let processObjectID = try coreAudioProcessObjectID(forPID: processID)
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "NoteAI-ProcessTap"

        // Create the process tap
        var tapObjectID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(description, &tapObjectID)
        guard status == noErr else {
            throw AudioCaptureError.processTapCreationFailed(status)
        }
        tapID = tapObjectID

        // Create an aggregate device that includes the tap
        aggregateDeviceID = try createAggregateDevice(tapID: tapID)

        // Set up AVAudioEngine to read from the aggregate device
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Configure the input to use our aggregate device
        try setAudioDevice(aggregateDeviceID, for: inputNode)

        let format = inputNode.outputFormat(forBus: 0)
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(format.sampleRate * 5) // 5-second chunks

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }

        try engine.start()
        audioEngine = engine
    }

    func stopTap() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }

        if aggregateDeviceID != 0 {
            destroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = 0
        }
    }

    deinit {
        stopTap()
    }

    // MARK: - Private

    private func coreAudioProcessObjectID(forPID processID: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = processID
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var objectIDSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &objectIDSize,
            &objectID
        )
        guard status == noErr else {
            throw AudioCaptureError.processObjectTranslationFailed(status)
        }
        guard objectID != kAudioObjectUnknown else {
            throw AudioCaptureError.processObjectNotFound(processID)
        }

        return objectID
    }

    private func createAggregateDevice(tapID: AudioObjectID) throws -> AudioObjectID {
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "NoteAI Aggregate",
            kAudioAggregateDeviceUIDKey as String: "com.noteai.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapID
                ]
            ]
        ]

        var aggregateDeviceID: AudioObjectID = 0
        let cfDescription = aggregateDescription as CFDictionary
        let status = AudioHardwareCreateAggregateDevice(cfDescription, &aggregateDeviceID)

        guard status == noErr else {
            throw AudioCaptureError.aggregateDeviceCreationFailed(status)
        }

        return aggregateDeviceID
    }

    private func destroyAggregateDevice(_ deviceID: AudioObjectID) {
        AudioHardwareDestroyAggregateDevice(deviceID)
    }

    private func setAudioDevice(_ deviceID: AudioObjectID, for node: AVAudioInputNode) throws {
        var deviceID = deviceID
        let status = AudioUnitSetProperty(
            node.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureError.deviceAssignmentFailed(status)
        }
    }
}

enum AudioCaptureError: LocalizedError {
    case processObjectTranslationFailed(OSStatus)
    case processObjectNotFound(pid_t)
    case processTapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case deviceAssignmentFailed(OSStatus)
    case screenCaptureNotAvailable
    case microphoneAccessDenied

    var errorDescription: String? {
        switch self {
        case .processObjectTranslationFailed(let status):
            return "Failed to translate process ID to Core Audio process object (OSStatus: \(status))"
        case .processObjectNotFound(let processID):
            return "No Core Audio process object found for PID \(processID)"
        case .processTapCreationFailed(let status):
            return "Failed to create process tap (OSStatus: \(status))"
        case .aggregateDeviceCreationFailed(let status):
            return "Failed to create aggregate device (OSStatus: \(status))"
        case .deviceAssignmentFailed(let status):
            return "Failed to assign audio device (OSStatus: \(status))"
        case .screenCaptureNotAvailable:
            return "Screen capture is not available"
        case .microphoneAccessDenied:
            return "Microphone access was denied"
        }
    }
}
