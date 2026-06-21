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

    func testAcceptsDroppingLongAccidentalClosingRepetition() {
        let repeatedClosing = String(repeating: "ya está ", count: 40)
        let raw = "mejora el servidor local y deja cada proveedor separado \(repeatedClosing)"
        let polished = "Mejora el servidor local y deja cada proveedor separado."
        let rawRatio = Double(polished.count) / Double(raw.count)

        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])

        XCTAssertLessThan(rawRatio, PolishFidelityGuard.minimumLengthRatio)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRejectsDroppingLongRepeatedNonFillerContent() {
        let raw = String(repeating: "deploy now ", count: 30)
        let polished = "Deploy now."
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

    func testAcceptsPunctuationFixInsideCapitalizedToken() {
        // Dictation typo `AGENTS..md` corrected to `AGENTS.md` — the polish did
        // its job; the guard must not reject it just because the literal anchor
        // (with the double dot) no longer matches.
        let raw = "actualiza el archivo AGENTS..md cuando termines la tarea pendiente del proyecto"
        let polished = "Actualiza el archivo AGENTS.md cuando termines la tarea pendiente del proyecto."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRejectsWhenCapitalizedTokenContentDropped() {
        // Dropping the `md` content (not just punctuation) must still fail: the
        // punctuation-insensitive key `agentsmd` no longer survives.
        let raw = "actualiza el archivo AGENTS..md cuando termines la tarea pendiente del proyecto"
        let polished = "Actualiza el archivo AGENTS cuando termines la tarea pendiente del proyecto."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testAllowsRemovingCapitalizedConversationalFillers() {
        let raw = "verifica eso y ya con eso para terminar Obviamente la base de datos personal no la subas"
        let polished = "Verifica eso y ya con eso para terminar; la base de datos personal no la subas."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAllowsChangingGenericCapitalizedWords() {
        let raw = "habla con Marketing para que revisen la presentación antes de la reunión"
        let polished = "Habla con el equipo de marketing para que revisen la presentación antes de la reunión."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRejectsWhenAcronymAnchorDisappears() {
        let raw = "documenta la API REST antes de cerrar el ticket del proyecto"
        let polished = "Documenta la interfaz antes de cerrar el ticket del proyecto."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testRejectsWhenNumberIsAbsorbedIntoLargerNumber() {
        // The raw "5" must not count as surviving inside the polished "15": a
        // plain substring match would wrongly accept a silently changed number.
        let raw = "confirmé que la reunión es a las 5 con el equipo de diseño del proyecto nuevo"
        let polished = "Confirmé que la reunión es a las 15 con el equipo de diseño del proyecto nuevo."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testRejectsWhenNumberGainsSeparator() {
        // "5" must not survive inside a different numeric token separated by
        // . , : — "5.5"/"5,000"/"5:30" are different numbers (semantic punctuation).
        for changed in ["5.5", "5,000", "5:30"] {
            let raw = "el total acordado con el proveedor de plataforma es 5 unidades por contrato"
            let polished = "El total acordado con el proveedor de plataforma es \(changed) unidades por contrato."
            let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
            XCTAssertFalse(verdict.isAcceptable, "should reject 5 -> \(changed)")
            XCTAssertGreaterThan(verdict.missingAnchors, 0)
        }
    }

    func testNumberAnchorStaysPunctuationSensitive() {
        // The punctuation tolerance is for capitalized words only; a number
        // anchor (`5.5`) must still be rejected when it becomes `55`.
        let raw = "la versión estable es la 5.5 según el informe técnico del equipo de plataforma"
        let polished = "La versión estable es la 55 según el informe técnico del equipo de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testRejectsWhenNumbersAreSwapped() {
        // Both numbers still appear, but assigned to the wrong nouns. A Set-based
        // check would accept this; the ordered subsequence catches the swap.
        let raw = "mueve 5 tickets al sprint 6 antes de la reunión del equipo de plataforma"
        let polished = "Mueve 6 tickets al sprint 5 antes de la reunión del equipo de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testRejectsWhenDuplicateNumberCountChanges() {
        // The raw says "5" twice; the polish silently turns the second into "15".
        // Deduplicating anchors would lose the count — the multiset-aware check
        // requires both 5s to survive.
        let raw = "cobra 5 ahora y 5 mañana al cliente nuevo del proyecto de plataforma"
        let polished = "Cobra 5 ahora y 15 mañana al cliente nuevo del proyecto de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testAcceptsRepeatedNumbersWhenPreserved() {
        // No false positive: the same two 5s survive verbatim.
        let raw = "cobra 5 ahora y 5 mañana al cliente nuevo del proyecto de plataforma"
        let polished = "Cobra 5 ahora y 5 mañana al cliente nuevo del proyecto de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsNormalizingMalformedMixedSeparatorNumber() {
        let raw = "el valor local de 0,63.40.64 sería algo de 30 unidades al mes y 10 unidades después"
        let polished = "El valor local de 0,63 o 0,64 sería algo de 30 unidades al mes y 10 unidades después."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testMissingNumberDoesNotCascadeToLaterNumbers() {
        let rawSequence = PolishFidelityGuard.orderedNumericTokens(
            in: "el costo era 1 y luego 2, después 3 y finalmente 4"
        )
        let missing = PolishFidelityGuard.missingNumericTokenCount(
            rawSequence: rawSequence,
            in: "El costo era 1 y después 3 y finalmente 4."
        )
        XCTAssertEqual(missing, 1)
    }

    func testRejectsChangingValidMixedSeparatorNumber() {
        let raw = "el total acordado fue 1,234.56 para el proveedor de plataforma"
        let polished = "El total acordado fue 1234.56 para el proveedor de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testAcceptsMovedURLWithInternalDigits() {
        // The URL's internal digit ("v2") must not join the numeric sequence: the
        // link is preserved but moved, and the only real number ("5") survives.
        let raw = "revisa https://acme.com/v2 y luego llama al 5 para coordinar la entrega"
        let polished = "Llama al 5 para coordinar la entrega y luego revisa https://acme.com/v2."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRejectsWhenURLAnchorChanges() {
        // The link itself is a literal anchor and must survive verbatim.
        let raw = "abre https://acme.com/alpha para revisar el informe del proyecto de plataforma"
        let polished = "Abre https://acme.com/beta para revisar el informe del proyecto de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertFalse(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testTranslationStillRequiresBothDuplicateNumbers() {
        // Numbers are translation-invariant: a translated polish that drops one of
        // the two 5s must be rejected even though words legitimately change.
        let raw = "avísale a ventas que enviamos 5 cajas el lunes y 5 cajas el martes a la bodega"
        let polished = "Tell sales we shipped 5 boxes on Monday and some boxes on Tuesday to the warehouse."
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [], translationExpected: true)
        XCTAssertFalse(verdict.isAcceptable, verdict.diagnosticSummary)
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
