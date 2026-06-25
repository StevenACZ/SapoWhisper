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

    func testAcceptsHeavySummarizationByRatio() {
        let raw = String(repeating: "tengo que revisar el módulo de pagos y el de facturación antes del viernes ", count: 4)
        let polished = "Revisar pagos."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertLessThan(verdict.lengthRatio, 0.55)
    }

    func testAcceptsDroppingLongAccidentalClosingRepetition() {
        let repeatedClosing = String(repeating: "ya está ", count: 40)
        let raw = "mejora el servidor local y deja cada proveedor separado \(repeatedClosing)"
        let polished = "Mejora el servidor local y deja cada proveedor separado."
        let rawRatio = Double(polished.count) / Double(raw.count)

        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])

        XCTAssertLessThan(rawRatio, 0.55)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsDroppingLongRepeatedNonFillerContent() {
        let raw = String(repeating: "deploy now ", count: 30)
        let polished = "Deploy now."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])

        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertLessThan(verdict.lengthRatio, 0.55)
    }

    func testAcceptsWhenNumberAnchorDisappears() {
        let raw = "la migración debe terminar antes del 2027 según el contrato firmado con Acme"
        let polished = "La migración debe terminar pronto según el contrato firmado con Acme."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertEqual(verdict.missingAnchors, 0)
    }

    func testAcceptsMinorNumericPruningInLongNarrativeDictation() {
        let setup = String(
            repeating: "Dale, como se dice, desarrolla esta parte de la historia con contexto y ejemplos reales. ",
            count: 11
        )
        let polishedSetup = String(
            repeating: "Desarrolla esta parte de la historia con contexto y ejemplos reales. ",
            count: 5
        )
        let raw = """
            \(setup)La pieza puede durar 15 o 14 minutos, con pausas, bromas internas y una reflexión final para que no quede tan seria. \
            También quiero que mantenga un tono humano, alegre por momentos, y que el narrador pueda romper la cuarta pared cuando haga falta.
            """
        let polished = """
            \(polishedSetup)La pieza puede durar 15 minutos, con pausas, bromas internas \
            y una reflexión final para que no quede tan seria. Mantén un tono humano, alegre por momentos, y deja que el narrador rompa la \
            cuarta pared cuando haga falta.
            """
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])

        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testLongNarrativeAcceptsDroppingOnlyNumber() {
        let setup = String(
            repeating: "Dale, como se dice, desarrolla esta parte de la historia con contexto y ejemplos reales. ",
            count: 14
        )
        let raw = """
            \(setup)La historia debe durar 15 minutos y cerrar con una reflexión clara para que el mensaje no se sienta vacío.
            """
        let polished = """
                Desarrolla esta parte de la historia con contexto y ejemplos reales. La historia debe cerrar con una reflexión clara para que \
                el mensaje no se sienta vacío.
            """
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])

        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertEqual(verdict.missingAnchors, 0)
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

    func testAcceptsWhenNumberIsAbsorbedIntoLargerNumber() {
        let raw = "confirmé que la reunión es a las 5 con el equipo de diseño del proyecto nuevo"
        let polished = "Confirmé que la reunión es a las 15 con el equipo de diseño del proyecto nuevo."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertEqual(verdict.missingAnchors, 0)
    }

    func testAcceptsWhenNumberGainsSeparator() {
        for changed in ["5.5", "5,000", "5:30"] {
            let raw = "el total acordado con el proveedor de plataforma es 5 unidades por contrato"
            let polished = "El total acordado con el proveedor de plataforma es \(changed) unidades por contrato."
            let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
            XCTAssertTrue(verdict.isAcceptable, "should accept 5 -> \(changed)")
            XCTAssertEqual(verdict.missingAnchors, 0)
        }
    }

    func testAcceptsChangedNumberPunctuation() {
        let raw = "la versión estable es la 5.5 según el informe técnico del equipo de plataforma"
        let polished = "La versión estable es la 55 según el informe técnico del equipo de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertEqual(verdict.missingAnchors, 0)
    }

    func testAcceptsWhenNumbersAreSwapped() {
        let raw = "mueve 5 tickets al sprint 6 antes de la reunión del equipo de plataforma"
        let polished = "Mueve 6 tickets al sprint 5 antes de la reunión del equipo de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertEqual(verdict.missingAnchors, 0)
    }

    func testAcceptsWhenDuplicateNumberCountChanges() {
        let raw = "cobra 5 ahora y 5 mañana al cliente nuevo del proyecto de plataforma"
        let polished = "Cobra 5 ahora y 15 mañana al cliente nuevo del proyecto de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertEqual(verdict.missingAnchors, 0)
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

    func testAcceptsChangingValidMixedSeparatorNumber() {
        let raw = "el total acordado fue 1,234.56 para el proveedor de plataforma"
        let polished = "El total acordado fue 1234.56 para el proveedor de plataforma."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertEqual(verdict.missingAnchors, 0)
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

    // MARK: - Instruction-response guard

    func testInstructionGuardAcceptsPolishedAssistantRequest() {
        let raw = "oye dime cinco más cinco y explícalo para ponerlo en el prompt"
        let polished = "Oye, dime cinco más cinco y explícalo para ponerlo en el prompt."
        let verdict = PolishInstructionResponseGuard.evaluate(raw: raw, polished: polished)

        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testInstructionGuardRejectsMathAnswer() {
        let raw = "dime cinco más cinco y explícalo"
        let polished = "Cinco más cinco es 10."
        let verdict = PolishInstructionResponseGuard.evaluate(raw: raw, polished: polished)

        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertNotNil(verdict.retryInstruction)
    }

    func testInstructionGuardRejectsAssistantRefusal() {
        let raw = "investígame por internet qué es WebRTC y dime las fuentes"
        let polished = "No puedo acceder a internet para buscar fuentes sobre WebRTC."
        let verdict = PolishInstructionResponseGuard.evaluate(raw: raw, polished: polished)

        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertNotNil(verdict.retryInstruction)
    }

    func testTranslationAcceptsDroppedDuplicateNumbers() {
        let raw = "avísale a ventas que enviamos 5 cajas el lunes y 5 cajas el martes a la bodega"
        let polished = "Tell sales we shipped 5 boxes on Monday and some boxes on Tuesday to the warehouse."
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [], translationExpected: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertEqual(verdict.missingAnchors, 0)
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
        XCTAssertLessThan(verdict.lengthRatio, 0.55)
    }

    func testAcceptsJapaneseTranslationBelowNormalFloor() {
        let raw = "avísale al equipo que la reunión de planificación se mueve para el final de la semana"
        let polished = "計画会議が今週の終わりに変更されたことをチームに知らせてください"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertLessThan(verdict.lengthRatio, 0.55)
    }

    func testAcceptsKoreanTranslationBelowNormalFloor() {
        let raw = "recuérdale al equipo de soporte que actualice la documentación antes de la próxima reunión"
        let polished = "다음 회의 전에 문서를 업데이트하라고 지원 팀에 상기시켜 주세요"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertLessThan(verdict.lengthRatio, 0.55)
    }

    func testAcceptsTruncatedChineseTranslationByRatio() {
        let raw = "necesito que revises el informe de ventas y me cuentes si todo quedó listo para la tarde"
        let polished = "好的"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertLessThan(verdict.lengthRatio, 0.15)
    }

    func testAcceptsRunawayChineseTranslationByRatio() {
        let raw = "hola equipo"
        let polished = String(repeating: "通知", count: 12)
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertGreaterThan(verdict.lengthRatio, 1.6)
    }

    func testMixedScriptOutputIsNotRejectedByRatio() {
        let raw = "necesito que revises el informe de ventas y me cuentes si todo quedó listo para la tarde"
        let polished = "revisa el reporte de ventas completo 报告"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true, targetIsDenseScript: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertGreaterThan(verdict.lengthRatio, 0.15)
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

    func testSanitizerStripsTranscriptDelimiters() {
        let output = """
            \(TranscriptPolishPromptBuilder.transcriptStartDelimiter)
            Hola equipo, mañana llego tarde.
            \(TranscriptPolishPromptBuilder.transcriptEndDelimiter)
            """

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
