#if DEBUG
    import Foundation
    import XCTest

    @testable import SapoWhisper

    final class STTNetworkFaultInjectionTests: XCTestCase {
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
