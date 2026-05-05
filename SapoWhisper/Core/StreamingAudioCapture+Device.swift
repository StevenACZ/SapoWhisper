//
//  StreamingAudioCapture+Device.swift
//  SapoWhisper
//

import AVFoundation
import AudioToolbox
import CoreAudio

extension StreamingAudioCapture {
    func bindPreferredInputDevice(to inputNode: AVAudioInputNode, deviceUID: String) throws -> AVAudioFormat? {
        guard deviceUID != AudioDevice.systemDefault.uid else { return nil }
        let deviceManager = AudioDeviceManager.shared
        guard let deviceID = deviceManager.getDeviceID(for: deviceUID),
            let audioUnit = inputNode.audioUnit
        else {
            throw RecordingError.deviceSelectionFailed(-1)
        }

        var targetDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &targetDeviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )

        guard status == noErr else {
            throw RecordingError.deviceSelectionFailed(status)
        }

        return queryDeviceInputFormat(deviceID: deviceID)
    }

    func queryDeviceInputFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }
}
