//
//  PolishFidelityTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class PolishFidelityTests: XCTestCase {

    // MARK: - Fidelity guard

    func testAcceptsLiteralCleanup() {
        let raw = "eh bueno quería decirte que mañana no puedo ir a la reunión de las 10 con Marketing"
        let polished = "Quería decirte que mañana no puedo ir a la reunión de las 10 con Marketing."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRejectsHeavySummarization() {
        let raw = String(repeating: "tengo que revisar el módulo de pagos y el de facturación antes del viernes ", count: 4)
        let polished = "Revisar pagos."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertLessThan(verdict.lengthRatio, PolishFidelityGuard.minimumLengthRatio)
    }

    func testRejectsWhenNumberAnchorDisappears() {
        let raw = "la migración debe terminar antes del 2027 según el contrato firmado con Acme"
        let polished = "La migración debe terminar pronto según el contrato firmado con Acme."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testAllowsRemovingSelfCorrectedAnchor() {
        let raw = "la reunión es a las 3 no espera quise decir a las 4 de la tarde con el equipo de Plataforma"
        let polished = "La reunión es a las 4 de la tarde con el equipo de Plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRejectsWhenVocabularyTermDisappears() {
        let raw = "hay que actualizar SapoWhisper para que el dictado funcione mejor en las llamadas largas"
        let polished = "Hay que actualizar la aplicación para que el dictado funcione mejor en las llamadas largas."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: ["SapoWhisper"])
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testAcceptsTranslationWhenOutputLanguageForcesIt() {
        let raw = "avísale al equipo de Ventas que la demo del producto queda para el 15 a las 3"
        let polished = "Let the Sales team know the product demo is set for the 15th at 3."
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [], translationExpected: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testTranslationStillRequiresNumbersAndVocabulary() {
        let raw = "dile a soporte que SapoWhisper falla desde la versión 2.3 en las llamadas largas de la mañana"
        let polished = "Tell support that the app has been failing on long morning calls."
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: ["SapoWhisper"], translationExpected: true)
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    // MARK: - Dense-script (CJK) translation floor

    func testAcceptsChineseTranslationBelowNormalFloor() {
        let raw = "necesito que revises el informe de ventas y me cuentes si todo quedó listo para la tarde"
        let polished = "我需要你检查销售报告并告诉我下午之前是否一切都准备好了"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        // Proves the fix matters: the ratio is below the normal floor.
        XCTAssertLessThan(verdict.lengthRatio, PolishFidelityGuard.minimumLengthRatio)
    }

    func testAcceptsJapaneseTranslationBelowNormalFloor() {
        let raw = "avísale al equipo que la reunión de planificación se mueve para el final de la semana"
        let polished = "計画会議が今週の終わりに変更されたことをチームに知らせてください"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertLessThan(verdict.lengthRatio, PolishFidelityGuard.minimumLengthRatio)
    }

    func testAcceptsKoreanTranslationBelowNormalFloor() {
        let raw = "recuérdale al equipo de soporte que actualice la documentación antes de la próxima reunión"
        let polished = "다음 회의 전에 문서를 업데이트하라고 지원 팀에 상기시켜 주세요"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertLessThan(verdict.lengthRatio, PolishFidelityGuard.minimumLengthRatio)
    }

    func testRejectsTruncatedChineseTranslation() {
        let raw = "necesito que revises el informe de ventas y me cuentes si todo quedó listo para la tarde"
        let polished = "好的"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertLessThan(verdict.lengthRatio, PolishFidelityGuard.denseScriptMinimumLengthRatio)
    }

    func testRejectsRunawayChineseTranslationByCeiling() {
        let raw = "hola equipo"
        let polished = String(repeating: "通知", count: 12)
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.lengthRatio, PolishFidelityGuard.maximumLengthRatio)
    }

    func testMixedScriptOutputKeepsNormalFloor() {
        // Half-translated output (mostly Spanish, a little Chinese): denseFraction
        // is below the threshold, so the normal floor stays and a sub-0.55 ratio
        // is still rejected even though it would clear the dense floor.
        let raw = "necesito que revises el informe de ventas y me cuentes si todo quedó listo para la tarde"
        let polished = "revisa el reporte de ventas completo 报告"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.lengthRatio, PolishFidelityGuard.denseScriptMinimumLengthRatio)
    }

    // MARK: - Output sanitizer

    func testSanitizerStripsWrappingCodeFence() {
        let output = "```\nHola, este es el texto final.\n```"
        XCTAssertEqual(
            PolishOutputSanitizer.clean(output, rawText: "hola este es el texto final"),
            "Hola, este es el texto final."
        )
    }

    func testSanitizerStripsPreambleLine() {
        let output = "Here's the polished text:\nHola equipo, mañana llego tarde."
        XCTAssertEqual(
            PolishOutputSanitizer.clean(output, rawText: "hola equipo mañana llego tarde"),
            "Hola equipo, mañana llego tarde."
        )
    }

    func testSanitizerStripsWrappingQuotes() {
        let output = "\"Hola equipo, mañana llego tarde.\""
        XCTAssertEqual(
            PolishOutputSanitizer.clean(output, rawText: "hola equipo mañana llego tarde"),
            "Hola equipo, mañana llego tarde."
        )
    }

    func testSanitizerKeepsQuotesWhenRawIsQuoted() {
        let output = "\"Hola equipo.\""
        XCTAssertEqual(
            PolishOutputSanitizer.clean(output, rawText: "\"hola equipo\""),
            "\"Hola equipo.\""
        )
    }

    // MARK: - Skip heuristics

    func testShouldSkipPolishForShortText() {
        XCTAssertTrue(TranscriptPostProcessor.shouldSkipPolish("hola"))
        XCTAssertTrue(TranscriptPostProcessor.shouldSkipPolish("ok dale listo"))
        XCTAssertFalse(
            TranscriptPostProcessor.shouldSkipPolish(
                "necesito que revises el pull request de la rama feature/login antes del mediodía"
            )
        )
    }
}
