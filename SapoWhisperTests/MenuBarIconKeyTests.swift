//
//  MenuBarIconKeyTests.swift
//  SapoWhisperTests
//
//  The menu bar icon only commits when the displayed image really changes:
//  every status item commit costs a synchronous round trip to the menu bar
//  host, so states sharing an asset must share a key.
//

@testable import SapoWhisper
import XCTest

@MainActor
final class MenuBarIconKeyTests: XCTestCase {

    private func key(_ state: AppState, loading: Bool = false) -> String {
        MenuBarIconImageProvider.iconKey(for: state, isLoadingLocalModel: loading)
    }

    func testStatesSharingAnAssetShareAKey() {
        XCTAssertEqual(key(.processing), key(.polishing))
        XCTAssertEqual(key(.idle), key(.noModel))
    }

    func testVisibleChangesProduceDistinctKeys() {
        XCTAssertNotEqual(key(.idle), key(.recording))
        XCTAssertNotEqual(key(.recording), key(.processing))
        XCTAssertNotEqual(key(.idle), key(.processing))
    }

    func testModelLoadingOverridesTheStateIcon() {
        XCTAssertEqual(key(.recording, loading: true), key(.idle, loading: true))
        XCTAssertNotEqual(key(.idle, loading: true), key(.idle))
    }

    func testTheKeyNamesTheBundledAsset() {
        XCTAssertEqual(key(.recording), "MenuBarIconRecording")
    }
}
