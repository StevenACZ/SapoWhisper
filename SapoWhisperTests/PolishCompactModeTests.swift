//
//  PolishCompactModeTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class PolishCompactModeTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "PolishCompactModeTests")!
        defaults.removePersistentDomain(forName: "PolishCompactModeTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "PolishCompactModeTests")
        defaults = nil
        super.tearDown()
    }

    // MARK: - PolishMode

    func testDefaultModeIsNormal() {
        XCTAssertEqual(PolishMode.current(defaults: defaults), .normal)
    }

    func testStoredCompactModeIsRead() {
        defaults.set("compact", forKey: Constants.StorageKeys.aiPolishMode)
        XCTAssertEqual(PolishMode.current(defaults: defaults), .compact)
    }

    func testUnknownStoredValueFallsBackToNormal() {
        defaults.set("turbo", forKey: Constants.StorageKeys.aiPolishMode)
        XCTAssertEqual(PolishMode.current(defaults: defaults), .normal)
    }

    /// Normal keeps the legacy "automatic" so old history rows and new rows
    /// read the same; compact is its own value.
    func testHistoryModeIdentifiers() {
        XCTAssertEqual(PolishMode.normal.historyModeIdentifier, "automatic")
        XCTAssertEqual(PolishMode.compact.historyModeIdentifier, "compact")
    }

    func testCompactIsActiveRequiresPolishEnabled() {
        defaults.set("compact", forKey: Constants.StorageKeys.aiPolishMode)
        defaults.set(false, forKey: Constants.StorageKeys.aiPolishEnabled)
        XCTAssertFalse(PolishMode.compactIsActive(defaults: defaults))
    }

    // MARK: - Compact prompt

    private func makeCompactSystem(
        outputLanguage: TranscriptPolishOutputLanguage = .sameAsInput,
        keyterms: [String] = [],
        replacements: [String: String] = [:]
    ) -> String {
        TranscriptPolishPromptBuilder.makeCompactMessages(
            rawText: "hola equipo",
            personalContext: "",
            outputLanguage: outputLanguage,
            keyterms: keyterms,
            replacements: replacements
        ).system
    }

    func testCompactPromptCarriesCompactContract() {
        let system = makeCompactSystem()
        XCTAssertTrue(system.contains("COMPACT rewrite rules"))
        XCTAssertTrue(system.contains("EXTRACT, then rewrite"))
        XCTAssertTrue(system.contains("ZERO requirement loss"))
        // The normal-mode filler contract must not leak into compact.
        XCTAssertFalse(system.contains("ALWAYS delete"))
    }

    func testCompactPromptKeepsDictionaryAndLanguagePriorities() {
        let system = makeCompactSystem(
            outputLanguage: .english,
            keyterms: ["PeekOCR"],
            replacements: ["buen mouse": "BuenMouse"]
        )
        XCTAssertTrue(system.contains("PRIORITY 1 — Output language:"))
        XCTAssertTrue(system.contains("PRIORITY 2 — User dictionary"))
        XCTAssertTrue(system.contains("PeekOCR, BuenMouse"))
        XCTAssertTrue(system.contains("Write the ENTIRE output in English"))
    }

    func testCompactUserMessageKeepsDelimiters() {
        let messages = TranscriptPolishPromptBuilder.makeCompactMessages(
            rawText: "texto de prueba",
            personalContext: "",
            outputLanguage: .sameAsInput,
            keyterms: [],
            replacements: [:]
        )
        XCTAssertTrue(messages.user.contains(TranscriptPolishPromptBuilder.transcriptStartDelimiter))
        XCTAssertTrue(messages.user.contains(TranscriptPolishPromptBuilder.transcriptEndDelimiter))
        XCTAssertTrue(messages.user.contains("texto de prueba"))
    }

    // MARK: - Content diff guard in compact mode

    /// Compact mode legitimately drops whole rambling passages; the cluster
    /// check must not fight the mode's job.
    func testCompactionSkipsDroppedClusterCheck() {
        let raw = """
            bueno entonces lo que quería contarte con mucho detalle innecesario es que \
            el despliegue de la aplicación salió bien y funcionó todo correctamente \
            y aparte también estuve revisando los reportes del mes pasado con calma
            """
        let verdict = PolishContentDiffGuard.evaluate(
            raw: raw,
            polished: "Deploy ok.",
            compactionExpected: true
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    /// Digits stay protected even under compaction.
    func testCompactionStillFlagsLostDigits() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "ponle 12 píxeles de padding y súbelo al puerto 8080",
            polished: "Ponle padding y súbelo.",
            compactionExpected: true
        )
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertEqual(verdict.lostDigitRuns, 2)
    }

    func testNormalModeStillFlagsDroppedClusters() {
        let raw = """
            primero quiero que revises el archivo de configuración del servidor porque \
            tiene un problema con los certificados que caducan mañana por la tarde
            """
        let verdict = PolishContentDiffGuard.evaluate(
            raw: raw,
            polished: "Hola.",
            compactionExpected: false
        )
        XCTAssertFalse(verdict.isAcceptable)
    }
}
