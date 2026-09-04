//
//  PolishFidelityTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

@MainActor
final class PolishFidelityTests: XCTestCase {

    // MARK: - Fidelity guard

    func testAcceptsLiteralCleanup() {
        let raw = "eh bueno quería decirte que mañana no puedo ir a la reunión de las 10 con Marketing"
        let polished = "Quería decirte que mañana no puedo ir a la reunión de las 10 con Marketing."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsHeavySummarization() {
        let raw = String(repeating: "tengo que revisar el módulo de pagos y el de facturación antes del viernes ", count: 4)
        let polished = "Revisar pagos."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
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

    func testRejectsDroppedLowercaseTechnicalAnchors() {
        let cases = [
            ("copia /tmp/cache antes de continuar", "Copia el cache antes de continuar."),
            ("carga el archivo .env antes de iniciar", "Carga el archivo antes de iniciar."),
            ("abre settings.json y revisa su contenido", "Abre la configuración y revisa su contenido."),
            ("ejecuta el comando con --force al final", "Ejecuta el comando al final."),
            ("haz git push origin main cuando termine", "Publica los cambios cuando termine."),
        ]

        for testCase in cases {
            let verdict = PolishFidelityGuard.evaluate(
                raw: testCase.0,
                polished: testCase.1,
                vocabularyTerms: []
            )
            XCTAssertFalse(verdict.isAcceptable, testCase.0)
            XCTAssertGreaterThan(verdict.missingAnchors, 0, testCase.0)
        }
    }

    func testTechnicalAnchorsRequireExactBoundaries() {
        let cases = [
            ("usa -f al terminar", "Usa --force al terminar."),
            ("borra /tmp/cache al terminar", "Borra /tmp/cache-old al terminar."),
        ]

        for testCase in cases {
            let verdict = PolishFidelityGuard.evaluate(raw: testCase.0, polished: testCase.1, vocabularyTerms: [])
            XCTAssertFalse(verdict.isAcceptable, testCase.0)
        }
    }

    func testAlphanumericIdentifiersStayExact() {
        XCTAssertFalse(
            PolishFidelityGuard.evaluate(raw: "usa api2 con H264", polished: "Usa api3 con H265.", vocabularyTerms: [])
                .isAcceptable)
        XCTAssertFalse(
            PolishFidelityGuard.evaluate(
                raw: "usa api2", polished: "Use api3.", vocabularyTerms: [], translationExpected: true
            ).isAcceptable)
    }

    func testGeneralShellCommandVerbStaysExact() {
        let verdict = PolishFidelityGuard.evaluate(
            raw: "ejecuta rm -rf /tmp/cache",
            polished: "Ejecuta cp -rf /tmp/cache.",
            vocabularyTerms: []
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testCapitalizedShellCommandIsExtracted() {
        let verdict = PolishFidelityGuard.evaluate(
            raw: "Git push origin main when ready.",
            polished: "Publish origin main when ready.",
            vocabularyTerms: []
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testTechnicalTokensPreserveCase() {
        let cases = [
            ("abre README.md", "Abre readme.md."),
            ("ejecuta con --force", "Ejecuta con --FORCE."),
        ]
        for testCase in cases {
            let verdict = PolishFidelityGuard.evaluate(
                raw: testCase.0,
                polished: testCase.1,
                vocabularyTerms: []
            )
            XCTAssertFalse(verdict.isAcceptable, testCase.0)
        }
    }

    func testNaturalLanguageMakeIsNotACommandAnchor() {
        let verdict = PolishFidelityGuard.evaluate(
            raw: "I need to make dinner before the meeting.",
            polished: "I need to prepare dinner before the meeting.",
            vocabularyTerms: []
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testContextualCommandIsNotPrunedByContainingPath() {
        let cases = [
            ("usa /tmp/makefile y ejecuta make", "Usa /tmp/makefile y ejecuta rm."),
            ("Keep /tmp/make; command make.", "Keep /tmp/make; command rm."),
        ]
        for testCase in cases {
            let verdict = PolishFidelityGuard.evaluate(
                raw: testCase.0,
                polished: testCase.1,
                vocabularyTerms: []
            )
            XCTAssertFalse(verdict.isAcceptable, testCase.0)
        }
    }

    func testLiteralAnchorsRejectPrefixAndSuffixMutations() {
        let cases = [
            ("abre https://acme.test/foo", "Abre https://acme.test/foo-old."),
            ("escribe a@b.test", "Escribe xa@b.test."),
        ]
        for testCase in cases {
            let verdict = PolishFidelityGuard.evaluate(
                raw: testCase.0,
                polished: testCase.1,
                vocabularyTerms: []
            )
            XCTAssertFalse(verdict.isAcceptable, testCase.0)
        }
    }

    func testCorrectionMarkerDoesNotMatchInsideLongerWord() {
        let verdict = PolishFidelityGuard.evaluate(
            raw: "en el código usa /tmp/cache",
            polished: "En el código usa cache.",
            vocabularyTerms: []
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testProtectsTechnicalAnchorAfterMoreThanSixtyEarlierAnchors() {
        let prefix = (0..<65).map { "config\($0).json" }.joined(separator: " ")
        let raw = "revisa \(prefix) y después elimina /tmp/cache"
        let polished = "Revisa \(prefix) y después elimina el cache."
        let verdict = PolishFidelityGuard.evaluate(raw: raw, polished: polished, vocabularyTerms: [])

        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.totalAnchors, 60)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    func testAllowsRemovingOneSelfCorrectedTechnicalAnchor() {
        let verdict = PolishFidelityGuard.evaluate(
            raw: "actualiza /tmp/old no espera usa /tmp/new para terminar",
            polished: "Actualiza /tmp/new para terminar.",
            vocabularyTerms: []
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRepeatedTechnicalAnchorOutsideCorrectionRemainsProtected() {
        let verdict = PolishFidelityGuard.evaluate(
            raw: "actualiza /tmp/old no espera usa /tmp/new y luego compara /tmp/old",
            polished: "Actualiza /tmp/new y termina.",
            vocabularyTerms: []
        )
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThan(verdict.missingAnchors, 0)
    }

    // MARK: - Instruction-response guard

    func testInstructionGuardAcceptsPolishedAssistantRequest() {
        let raw = "oye dime cinco más cinco y explícalo para ponerlo en el prompt"
        let polished = "Oye, dime cinco más cinco y explícalo para ponerlo en el prompt."
        let verdict = PolishInstructionResponseGuard.evaluate(raw: raw, polished: polished)

        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testInstructionGuardRejectsAssistantRefusal() {
        let raw = "investígame por internet qué es WebRTC y dime las fuentes"
        let polished = "No puedo acceder a internet para buscar fuentes sobre WebRTC."
        let verdict = PolishInstructionResponseGuard.evaluate(raw: raw, polished: polished)

        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertNotNil(verdict.retryInstruction)
    }

    /// Real regression: a Spanish dictation containing a cue verb ("genera")
    /// translated to English loses that cue ("generates" matches no EN
    /// pattern), so the cross-language cue-preservation check rejected every
    /// faithful translation and the untranslated text shipped. Cue
    /// preservation is gone (2026-08-29): the output carries no introduced
    /// assistant marker, so it is acceptable in every mode.
    func testInstructionGuardAcceptsFaithfulTranslationLosingSourceCue() {
        let raw = "sería bueno que la ventana que genera el resumen se cierre cuando doy clic afuera"
        let polished = "It would be good if the window that generates the summary closed when I click outside."

        let translated = PolishInstructionResponseGuard.evaluate(
            raw: raw, polished: polished, translationExpected: true)
        XCTAssertTrue(translated.isAcceptable, translated.diagnosticSummary)

        let sameLanguage = PolishInstructionResponseGuard.evaluate(
            raw: raw, polished: polished, translationExpected: false)
        XCTAssertTrue(sameLanguage.isAcceptable, sameLanguage.diagnosticSummary)
    }

    /// Introduced assistant markers must survive the translation relaxation —
    /// they match the polished text itself.
    func testInstructionGuardStillRejectsAnswersWhenTranslating() {
        let raw = "dime cuánto es cinco más cinco"
        let polished = "Claro, aquí tienes la traducción: five plus five is 10."
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: raw, polished: polished, translationExpected: true)

        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertNotNil(verdict.retryInstruction)
    }

    /// Real regression: everyday dictations legitimately contain
    /// response-like phrases ("no puedo", "claro,", "here's"), and the guard
    /// rejected any polished text containing them — burning the whole retry
    /// budget and shipping the raw text. A phrase only signals drift when the
    /// model introduced it (present in polished, absent from raw).
    func testInstructionGuardAcceptsEverydaySpeechContainingResponsePhrases() {
        let cases: [(raw: String, polished: String)] = [
            (
                "eh quería decirte que mañana no puedo ir a la reunión de las 10 con Marketing",
                "Quería decirte que mañana no puedo ir a la reunión de las 10 con Marketing."
            ),
            (
                "no encontré el archivo de configuración así que usé el default",
                "No encontré el archivo de configuración, así que usé el default."
            ),
            (
                "bueno claro mándame el reporte cuando lo tengas listo",
                "Claro, mándame el reporte cuando lo tengas listo."
            ),
            (
                "okay so here's the plan we ship on monday and review on friday",
                "Here's the plan: we ship on Monday and review on Friday."
            ),
            (
                "le dije que no puedo correr la maratón este año por la lesión",
                "Le dije que no puedo correr la maratón este año por la lesión."
            ),
            (
                "i can't make it to standup tomorrow so please record it",
                "I can't make it to standup tomorrow, so please record it."
            ),
            (
                "por supuesto el resultado es mejor con el modelo nuevo",
                "Por supuesto, el resultado es mejor con el modelo nuevo."
            ),
        ]
        for testCase in cases {
            let verdict = PolishInstructionResponseGuard.evaluate(raw: testCase.raw, polished: testCase.polished)
            XCTAssertTrue(verdict.isAcceptable, "should accept: \(testCase.polished)")
        }
    }

    /// Real regression (2026-07-05): a compact rewrite of an instruction-heavy
    /// dictation rephrases imperative cues into requirement wording, so the
    /// cue-preservation check found none of the literal cue verbs and rejected
    /// every attempt (3/3, raw shipped) even though the compaction was good.
    /// Cue preservation is gone (2026-08-29): both modes accept it.
    func testInstructionGuardAcceptsCompactRewriteLosingCueVerbs() {
        let raw =
            "ya elimina el motor local antiguo y haz una mejor componentización revisa que los modelos se guarden bien y analiza el espacio usado"
        let polished =
            "Eliminación del motor local antiguo, mejor componentización, verificación del guardado de modelos y del espacio usado."

        let compact = PolishInstructionResponseGuard.evaluate(
            raw: raw, polished: polished, compactionExpected: true)
        XCTAssertTrue(compact.isAcceptable, compact.diagnosticSummary)

        let normal = PolishInstructionResponseGuard.evaluate(raw: raw, polished: polished)
        XCTAssertTrue(normal.isAcceptable, normal.diagnosticSummary)
    }

    func testInstructionGuardRejectsIntroducedRefusalOpener() {
        // The model's own refusal wording is never in the transcript.
        let raw = "resume el documento de arquitectura en tres puntos para el equipo"
        let polished = "No puedo resumir documentos que no me has proporcionado."
        let verdict = PolishInstructionResponseGuard.evaluate(raw: raw, polished: polished)

        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertNotNil(verdict.retryInstruction)
    }

    func testInstructionGuardAllowsSpokenFilenamePunctuationCorrection() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "No borres settings punto json.",
            polished: "No borres settings.json."
        )

        XCTAssertTrue(verdict.isAcceptable)
    }

    func testTranslationAcceptsDroppedDuplicateNumbers() {
        let raw = "avísale a ventas que enviamos 5 cajas el lunes y 5 cajas el martes a la bodega"
        let polished = "Tell sales we shipped 5 boxes on Monday and some boxes on Tuesday to the warehouse."
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [], translationExpected: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertEqual(verdict.missingAnchors, 0)
    }

    // MARK: - CJK translation acceptance

    func testAcceptsChineseTranslationBelowNormalFloor() {
        let raw = "necesito que revises el informe de ventas y me cuentes si todo quedó listo para la tarde"
        let polished = "我需要你检查销售报告并告诉我下午之前是否一切都准备好了"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsJapaneseTranslationBelowNormalFloor() {
        let raw = "avísale al equipo que la reunión de planificación se mueve para el final de la semana"
        let polished = "計画会議が今週の終わりに変更されたことをチームに知らせてください"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsKoreanTranslationBelowNormalFloor() {
        let raw = "recuérdale al equipo de soporte que actualice la documentación antes de la próxima reunión"
        let polished = "다음 회의 전에 문서를 업데이트하라고 지원 팀에 상기시켜 주세요"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRejectsTruncatedChineseTranslation() {
        let raw = "necesito que revises el informe de ventas y me cuentes si todo quedó listo para la tarde"
        let polished = "好的"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true)
        XCTAssertFalse(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertTrue(verdict.translationShapeMismatch)
    }

    func testRejectsRunawayChineseTranslation() {
        let raw = "hola equipo"
        let polished = String(repeating: "通知", count: 12)
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true)
        XCTAssertFalse(verdict.isAcceptable, verdict.diagnosticSummary)
        XCTAssertTrue(verdict.translationShapeMismatch)
    }

    func testMixedScriptOutputIsNotRejected() {
        let raw = "necesito que revises el informe de ventas y me cuentes si todo quedó listo para la tarde"
        let polished = "revisa el reporte de ventas completo 报告"
        let verdict = PolishFidelityGuard.evaluate(
            raw: raw, polished: polished, vocabularyTerms: [],
            translationExpected: true)
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
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

    func testSanitizerStripsLeadingThinkingBlock() {
        let output = "<think>\nThe user wants the filler removed.\n</think>\nHola equipo, mañana llego tarde."
        XCTAssertEqual(
            PolishOutputSanitizer.clean(output, rawText: "hola equipo mañana llego tarde"),
            "Hola equipo, mañana llego tarde."
        )
    }

    func testSanitizerKeepsInlineThinkMention() {
        let output = "El tag <think> se usa en el parser."
        XCTAssertEqual(
            PolishOutputSanitizer.clean(output, rawText: "el tag think se usa en el parser"),
            "El tag <think> se usa en el parser."
        )
    }

}
