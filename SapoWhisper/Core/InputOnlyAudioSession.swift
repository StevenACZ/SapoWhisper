@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

nonisolated final class InputOnlyAudioSession: @unchecked Sendable {
    let format: AVAudioFormat
    let deviceID: AudioDeviceID
    private let unit: AudioUnit
    private let context: InputOnlyAudioContext
    private let callbackContext: Unmanaged<InputOnlyAudioContext>
    private let stateLock = NSLock()
    private var running = false
    private var closed = false

    var isRunning: Bool { stateLock.withLock { running } }

    init(unit: AudioUnit, callbackContext: Unmanaged<InputOnlyAudioContext>, deviceID: AudioDeviceID) {
        self.unit = unit
        self.callbackContext = callbackContext
        context = callbackContext.takeUnretainedValue()
        self.deviceID = deviceID
        format = context.buffer.format
    }

    deinit { close() }

    // Lifecycle calls are serialized off the audio thread; callbacks must never call them.
    func start() throws {
        guard !closed else { throw Self.statusError(kAudioUnitErr_Uninitialized) }
        guard !isRunning else { return }
        context.activate()
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            context.deactivate()
            _ = AudioOutputUnitStop(unit)
            context.waitForCallbacks()
            throw Self.statusError(status)
        }
        stateLock.withLock { running = true }
    }

    func pause() {
        guard !closed else { return }
        context.deactivate()
        let status = AudioOutputUnitStop(unit)
        context.waitForCallbacks()
        stateLock.withLock { running = false }
        if status != noErr {
            context.reportError(status)
            context.drainDelivery()
        }
    }

    func close() {
        guard !closed else { return }
        pause()
        closed = true
        let uninitializeStatus = AudioUnitUninitialize(unit)
        let disposeStatus = AudioComponentInstanceDispose(unit)
        // Failed disposal retains the C refcon because the unit may still invoke it.
        if disposeStatus == noErr { callbackContext.release() }
        withExtendedLifetime(context) {
            if uninitializeStatus != noErr { context.reportError(uninitializeStatus) }
            if disposeStatus != noErr { context.reportError(disposeStatus) }
            context.drainDelivery()
        }
    }

    static func statusError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw statusError(status) }
    }
}
