import XCTest

@testable import SapoWhisper

final class PolishInstructionResponseGuardTests: XCTestCase {
    func testRejectsDroppedCommonTechnicalImperativesInNormalMode() {
        let cases = [
            ("actualiza la API antes del viernes", "La API estará lista antes del viernes."),
            ("elimina el cache cuando termine", "El cache queda disponible cuando termine."),
            ("deploy the service after review", "The service is ready after review."),
            ("restart the worker after the build", "The worker is ready after the build."),
        ]

        for testCase in cases {
            let verdict = PolishInstructionResponseGuard.evaluate(raw: testCase.0, polished: testCase.1)
            XCTAssertFalse(verdict.isAcceptable, testCase.0)
        }
    }

    func testPreservedImperativeIsAcceptedWhenAnotherCueAppearsAsContent() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "deploy the service after review",
            polished: "Deploy the service after review."
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testNounCuesDoNotBecomeRequiredActions() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Review the logs after the build, then deploy the service.",
            polished: "Review the logs after the build, then deploy the service."
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testFaithfulRequestVerbParaphraseIsAccepted() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Por favor revisa el reporte.",
            polished: "Por favor verifica el reporte."
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testDroppingOneOfMultipleActionsIsRejected() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Review the logs, then deploy the service.",
            polished: "Review the logs."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testDroppingOneOfTwoObjectsWithTheSameActionIsRejected() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Revisa los logs y revisa el deploy.",
            polished: "Revisa los logs."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testCombiningEquivalentReviewActionsPreservesBothObjects() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Revisa logs y verifica métricas.",
            polished: "Comprueba logs y métricas."
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testActionObjectsCannotSwapBetweenDestructiveAndUpdateVerbs() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Delete cache. Update docs.",
            polished: "Delete docs. Update cache."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testActionObjectsCannotSwapBetweenCopyAndOpen() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Copia el archivo y abre la carpeta.",
            polished: "Copia la carpeta y abre el archivo."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testUncategorizedActionCannotBecomeDestructive() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Review logs.",
            polished: "Delete logs."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testLeadingEnglishNounIsNotAnImperative() {
        let cases = [
            ("Review begins tomorrow.", "The review begins tomorrow."),
            ("Review failed yesterday.", "The review failed yesterday."),
        ]
        for testCase in cases {
            let verdict = PolishInstructionResponseGuard.evaluate(raw: testCase.0, polished: testCase.1)
            XCTAssertTrue(verdict.isAcceptable, testCase.0)
        }
    }

    func testMergingARepeatedRequestIsAccepted() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Revisa el reporte, o sea, revisa el reporte.",
            polished: "Revisa el reporte."
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testStandaloneActionWithoutObjectIsAccepted() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Reinicia.",
            polished: "Reinicia."
        )

        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRestrictionInSupersededClauseIsIgnored() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "No borres cache, no espera, borra cache.",
            polished: "Borra cache."
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testCorrectionKeepsEarlierUnrelatedRestriction() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "No borres cache y actualiza logs, no espera, actualiza métricas.",
            polished: "Borra cache y actualiza métricas."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testRestrictionMustStayAttachedToItsObject() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Actualiza el servicio, pero no actualiza el cache.",
            polished: "Actualiza el cache, pero no actualiza el servicio."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testRestrictionQualifierCannotChangeEnvironment() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "No borres cache de producción.",
            polished: "No borres cache de staging."
        )

        XCTAssertFalse(verdict.isAcceptable)
    }

    func testCommonUseCuePreservesRestriction() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Usa el servidor sin reiniciar la base.",
            polished: "Usa el servidor y reinicia la base."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testRejectsDroppedSpanishRestrictionsInNormalMode() {
        let cases = [
            ("actualiza el servicio pero no borres el cache", "Actualiza el servicio y borra el cache."),
            ("reinicia el servicio pero nunca uses force", "Reinicia el servicio usando force."),
            ("despliega el cambio sin reiniciar la base", "Despliega el cambio y reinicia la base."),
            ("borra los archivos excepto el env", "Borra los archivos y el env."),
        ]

        for testCase in cases {
            let verdict = PolishInstructionResponseGuard.evaluate(raw: testCase.0, polished: testCase.1)
            XCTAssertFalse(verdict.isAcceptable, testCase.0)
        }
    }

    func testRejectsDroppedEnglishRestrictionsInNormalMode() {
        let cases = [
            ("update the service but do not delete the cache", "Update the service and delete the cache."),
            ("restart the service but never use force", "Restart the service using force."),
            ("deploy without restarting the database", "Deploy and restart the database."),
            ("delete every file except env", "Delete every file including env."),
        ]

        for testCase in cases {
            let verdict = PolishInstructionResponseGuard.evaluate(raw: testCase.0, polished: testCase.1)
            XCTAssertFalse(verdict.isAcceptable, testCase.0)
        }
    }

    func testRestrictionPreservationIsExemptForTranslationButNotCompact() {
        let raw = "actualiza el servicio sin reiniciar la base"
        let polished = "Service update with database availability."

        XCTAssertTrue(
            PolishInstructionResponseGuard.evaluate(
                raw: raw,
                polished: polished,
                translationExpected: true
            ).isAcceptable)
        XCTAssertFalse(
            PolishInstructionResponseGuard.evaluate(
                raw: raw,
                polished: polished,
                compactionExpected: true
            ).isAcceptable)

        XCTAssertTrue(
            PolishInstructionResponseGuard.evaluate(
                raw: raw,
                polished: "Actualizar servicio sin reiniciar base.",
                compactionExpected: true
            ).isAcceptable)
    }

    func testTranslationRejectsIntroducedCapabilityRefusal() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Investiga WebRTC.",
            polished: "I cannot access the internet.",
            translationExpected: true
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testTranslationAcceptsEquivalentResponseLikeWordingFromSource() {
        for raw in ["Aquí está el plan.", "Acá está el plan.", "Ahí está el plan."] {
            let verdict = PolishInstructionResponseGuard.evaluate(
                raw: raw,
                polished: "Here is the plan.",
                translationExpected: true
            )
            XCTAssertTrue(verdict.isAcceptable, raw)
        }
    }

    func testEquivalentUncategorizedRequestParaphraseIsAccepted() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "Dime las fuentes.",
            polished: "Cuéntame las fuentes."
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testSelfCorrectionNoDoesNotBecomeARestriction() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "actualiza cache no espera usa storage",
            polished: "Usa storage."
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }
}
