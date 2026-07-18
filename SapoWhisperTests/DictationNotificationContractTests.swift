import Foundation
import Testing

@testable import SapoWhisper

@Suite("Dictation notification contract")
struct DictationNotificationContractTests {
    @Test("Notification names stay stable for companion apps")
    func stableNames() {
        #expect(
            DictationStateBroadcaster.toggleRequestedNotification.rawValue
                == "oli.SapoWhisper.dictation.toggle"
        )
        #expect(
            DictationStateBroadcaster.recordingBeganNotification.rawValue
                == "oli.SapoWhisper.dictation.began"
        )
        #expect(
            DictationStateBroadcaster.recordingEndedNotification.rawValue
                == "oli.SapoWhisper.dictation.ended"
        )
        #expect(DictationStateBroadcaster.remoteInputDeviceUID == "MiradorMicrophone_UID")
    }
}
