#if DEBUG
    import Foundation
    import XCTest

    @testable import SapoWhisper

    final class STTNetworkFaultInjectionTests: XCTestCase {
        func testUploadStallLeavesHealthAndOtherHostsAvailable() {
            let host = "stt.example.invalid"
            XCTAssertEqual(
                STTNetworkFaultInjection.mode(
                    URL(string: "http://stt.example.invalid/v1/audio/transcriptions"), failures: ["local-stall"], localHost: host),
                .stalled
            )
            for url in [
                "http://stt.example.invalid/health", "http://stt.example.invalid/v1/models",
                "https://api.deepgram.com/v1/listen", "http://other.example.invalid/v1/audio/transcriptions",
                "file:///v1/audio/transcriptions",
            ] {
                XCTAssertNil(STTNetworkFaultInjection.mode(URL(string: url), failures: ["local-stall"], localHost: host))
            }
        }

        func testFaultsAreScopedToTheSelectedSTTHosts() {
            let local = URL(string: "http://stt.example.invalid:8000/health")
            let cloud = URL(string: "https://api.deepgram.com/v1/listen")
            XCTAssertFalse(STTNetworkFaultInjection.matches(local, failures: [], localHost: "stt.example.invalid"))
            XCTAssertTrue(STTNetworkFaultInjection.matches(local, failures: ["local"], localHost: "stt.example.invalid"))
            XCTAssertFalse(STTNetworkFaultInjection.matches(cloud, failures: ["local"], localHost: "stt.example.invalid"))
            XCTAssertTrue(STTNetworkFaultInjection.matches(cloud, failures: ["deepgram"], localHost: nil))
            for url in [
                "https://api.deepgram.com.example.invalid/v1/listen", "https://example.invalid", "file:///tmp/fixture",
                "wss://api.deepgram.com/v1/listen",
            ] {
                XCTAssertFalse(STTNetworkFaultInjection.matches(URL(string: url), failures: ["local", "deepgram"], localHost: nil))
            }
        }
    }
#endif
