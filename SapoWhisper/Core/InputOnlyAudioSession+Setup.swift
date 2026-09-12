@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio

nonisolated extension InputOnlyAudioSession {
    static func prepare(
        deviceID: AudioDeviceID,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onError: @escaping @Sendable (OSStatus) -> Void
    ) throws -> InputOnlyAudioSession {
        guard deviceID != kAudioObjectUnknown else {
            throw RecordingError.deviceSelectionFailed(kAudioUnitErr_InvalidPropertyValue)
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecordingError.engineCreationFailed
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance))
        guard let unit = instance else { throw RecordingError.engineCreationFailed }
        var context: InputOnlyAudioContext?
        var callbackContext: Unmanaged<InputOnlyAudioContext>?
        var adopted = false
        defer {
            if !adopted {
                context?.deactivate()
                _ = AudioOutputUnitStop(unit)
                context?.waitForCallbacks()
                _ = AudioUnitUninitialize(unit)
                if AudioComponentInstanceDispose(unit) == noErr { callbackContext?.release() }
                withExtendedLifetime(context) {}
            }
        }
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
        try set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0))
        do {
            try set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, deviceID)
            var bound = AudioDeviceID(kAudioObjectUnknown)
            try get(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &bound)
            guard bound == deviceID else {
                throw statusError(kAudioUnitErr_InvalidPropertyValue)
            }
        } catch {
            throw RecordingError.deviceSelectionFailed(OSStatus((error as NSError).code))
        }
        var hardware = AudioStreamBasicDescription()
        try get(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware)
        guard hardware.mSampleRate.isFinite, hardware.mSampleRate > 0,
            hardware.mChannelsPerFrame > 0,
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                channels: hardware.mChannelsPerFrame, interleaved: false
            )
        else { throw RecordingError.invalidFormat }
        try set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format.streamDescription.pointee)
        var actual = AudioStreamBasicDescription()
        try get(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &actual)
        guard let actualFormat = AVAudioFormat(streamDescription: &actual), actualFormat == format else {
            throw RecordingError.invalidFormat
        }
        var maximumFrames: UInt32 = 0
        try get(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames)
        try set(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, max(maximumFrames, 16_384))
        try get(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames)
        let preparedContext = try InputOnlyAudioContext(
            unit: unit, format: format, maximumFrames: maximumFrames,
            onBuffer: onBuffer, onError: onError
        )
        context = preparedContext
        let retainedContext = Unmanaged.passRetained(preparedContext)
        callbackContext = retainedContext
        let callback = AURenderCallbackStruct(
            inputProc: inputOnlyAudioCallback,
            inputProcRefCon: retainedContext.toOpaque()
        )
        try set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, callback)
        try check(AudioUnitInitialize(unit))
        try get(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames)
        guard maximumFrames > 0, maximumFrames <= preparedContext.buffer.frameCapacity else {
            throw statusError(kAudioUnitErr_TooManyFramesToProcess)
        }
        let session = InputOnlyAudioSession(unit: unit, callbackContext: retainedContext, deviceID: deviceID)
        adopted = true
        return session
    }

    private static func set<T>(
        _ unit: AudioUnit, _ property: AudioUnitPropertyID,
        _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: T
    ) throws {
        try withUnsafeBytes(of: value) { bytes in
            try check(AudioUnitSetProperty(unit, property, scope, element, bytes.baseAddress, UInt32(bytes.count)))
        }
    }

    private static func get<T>(
        _ unit: AudioUnit, _ property: AudioUnitPropertyID,
        _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: inout T
    ) throws {
        try withUnsafeMutableBytes(of: &value) { bytes in
            var size = UInt32(bytes.count)
            try check(AudioUnitGetProperty(unit, property, scope, element, bytes.baseAddress!, &size))
            guard size == bytes.count else { throw statusError(kAudioUnitErr_InvalidPropertyValue) }
        }
    }
}
