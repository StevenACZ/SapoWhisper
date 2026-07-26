//
//  HotkeyDefaultsTests.swift
//  SapoWhisperTests
//

import Carbon
import XCTest

@testable import SapoWhisper

/// Stored hotkey values are Carbon `UInt32`s persisted as `Int`. Two ways that
/// bites: an out-of-range value traps the conversion at launch, and key code 0
/// (`kVK_ANSI_A`) is a real key that a `> 0` check silently turns back into
/// Space.
final class HotkeyDefaultsTests: XCTestCase {

    private let suiteName = "test.sapowhisper.hotkey.\(UUID().uuidString)"

    func testAbsentKeyCodeFallsBackToTheDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(HotkeyManager.storedKeyCode(in: defaults), Constants.Hotkey.defaultKeyCode)
    }

    func testStoredZeroIsTheAKeyNotTheDefault() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Int(kVK_ANSI_A), forKey: Constants.StorageKeys.hotkeyKeyCode)

        XCTAssertEqual(HotkeyManager.storedKeyCode(in: defaults), UInt32(kVK_ANSI_A))
    }

    func testOutOfRangeKeyCodeFallsBackWithoutTrapping() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(-1, forKey: Constants.StorageKeys.hotkeyKeyCode)
        XCTAssertEqual(HotkeyManager.storedKeyCode(in: defaults), Constants.Hotkey.defaultKeyCode)

        defaults.set(Int(UInt32.max) + 1, forKey: Constants.StorageKeys.hotkeyKeyCode)
        XCTAssertEqual(HotkeyManager.storedKeyCode(in: defaults), Constants.Hotkey.defaultKeyCode)
    }

    /// A modifier mask is different: the recorder refuses a bare key, so an
    /// empty mask is as unusable as a corrupted one.
    func testModifierMaskRejectsEmptyAndOutOfRangeValues() {
        XCTAssertEqual(
            HotkeyManager.sanitizedModifiers(0, fallback: Constants.Hotkey.defaultModifiers),
            Constants.Hotkey.defaultModifiers
        )
        XCTAssertEqual(
            HotkeyManager.sanitizedModifiers(-2048, fallback: Constants.Hotkey.defaultModifiers),
            Constants.Hotkey.defaultModifiers
        )
        XCTAssertEqual(
            HotkeyManager.sanitizedModifiers(Int(optionKey), fallback: Constants.Hotkey.defaultModifiers),
            UInt32(optionKey)
        )
    }
}

/// The launch half of the same defect: a poisoned UserDefaults must not take
/// the app down before it can show a window.
///
/// The poison goes into the ARGUMENT domain, never the persistent one. It
/// outranks the app's own values for reads, but a trap here would kill the
/// process before any teardown ran — and a persistent -1 left behind is
/// exactly the "app cannot launch, recover with `defaults delete`" state this
/// test exists to prevent.
@MainActor
final class PoisonedHotkeyLaunchTests: XCTestCase {

    private let defaults = UserDefaults.standard
    private var previousArguments: [String: Any]?
    private struct HotkeySnapshot {
        let kind: HotkeyTriggerKind
        let keyCode: UInt32
        let modifiers: UInt32
        let doubleTap: UInt32
    }
    private var liveHotkey: HotkeySnapshot?

    override func setUp() {
        super.setUp()
        let manager = HotkeyManager.shared
        liveHotkey = HotkeySnapshot(
            kind: manager.currentTriggerKind,
            keyCode: manager.currentKeyCode,
            modifiers: manager.currentModifiers,
            doubleTap: manager.currentDoubleTapModifier
        )
        previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    override func tearDown() {
        if let previousArguments {
            defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain)
        }
        previousArguments = nil
        if let liveHotkey {
            let manager = HotkeyManager.shared
            manager.currentTriggerKind = liveHotkey.kind
            manager.currentKeyCode = liveHotkey.keyCode
            manager.currentModifiers = liveHotkey.modifiers
            manager.currentDoubleTapModifier = liveHotkey.doubleTap
        }
        liveHotkey = nil
        super.tearDown()
    }

    func testViewModelInitSurvivesANegativeStoredHotkey() throws {
        var arguments = try XCTUnwrap(previousArguments)
        // Cloud primary so ViewModel init never touches the local model loader.
        arguments[Constants.StorageKeys.transcriptionEngine] = TranscriptionEngine.deepgram.rawValue
        arguments[Constants.StorageKeys.hotkeyKeyCode] = -1
        arguments[Constants.StorageKeys.hotkeyModifiers] = -2048
        arguments[Constants.StorageKeys.hotkeyDoubleTapModifier] = -2048
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        XCTAssertEqual(defaults.integer(forKey: Constants.StorageKeys.hotkeyKeyCode), -1)

        _ = SapoWhisperViewModel()

        let manager = HotkeyManager.shared
        XCTAssertEqual(manager.currentKeyCode, Constants.Hotkey.defaultKeyCode)
        XCTAssertEqual(manager.currentModifiers, Constants.Hotkey.defaultModifiers)
        XCTAssertEqual(manager.currentDoubleTapModifier, Constants.Hotkey.defaultDoubleTapModifier)
    }
}
