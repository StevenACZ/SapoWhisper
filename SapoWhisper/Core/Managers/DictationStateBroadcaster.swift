import Foundation
import os

/// Broadcasts the dictation recording lifecycle over distributed notifications
/// so companion apps on this Mac can react — e.g. Mirador Host ducks its
/// outgoing system-audio stream, which taps app audio before the device-volume
/// stage and therefore never hears AutoDuckingManager's local ducking.
///
/// The notification names are a stable public contract; no payload is ever
/// attached (nothing private leaves the app).
enum DictationStateBroadcaster {
    static let recordingBeganNotification = Notification.Name("oli.SapoWhisper.dictation.began")
    static let recordingEndedNotification = Notification.Name("oli.SapoWhisper.dictation.ended")

    /// Posts on the recording edges of an `appState` change; every other
    /// transition stays silent.
    static func broadcast(from oldState: AppState, to newState: AppState) {
        let wasRecording = oldState == .recording
        let isRecording = newState == .recording
        guard wasRecording != isRecording else { return }
        post(isRecording ? recordingBeganNotification : recordingEndedNotification)
        SapoLog.recording.info(
            "dictation broadcast \(isRecording ? "began" : "ended", privacy: .public)"
        )
    }

    /// Safety net for app termination: a listener must never stay ducked
    /// because the ended edge was lost with the process.
    static func broadcastRecordingEnded() {
        post(recordingEndedNotification)
    }

    private static func post(_ name: Notification.Name) {
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
