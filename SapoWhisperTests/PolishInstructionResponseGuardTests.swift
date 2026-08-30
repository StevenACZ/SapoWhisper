import XCTest

@testable import SapoWhisper

final class PolishInstructionResponseGuardTests: XCTestCase {
    func testAcceptsSpanishCompactRewriteWithDroppedNegationAndChangedVoice() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "actualiza el servicio pero no borres el cache, no sé si se pueda, ahí dale por favor",
            polished: "Actualizar el servicio y borrar el cache.",
            compactionExpected: true
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsEnglishCompactRewriteWithRewordedCommandPathAndURL() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "run npm run build in /srv/app and then check https://example.com/status, do not restart the database",
            polished: "The build must run in the application directory and the status page must be checked afterwards.",
            compactionExpected: true
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsCompactRewriteThatRephrasesAFileInstruction() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "borra el archivo punto env del server, no, mejor solo revísalo",
            polished: "Revisar el archivo .env del servidor.",
            compactionExpected: true
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsTranslationOfAnInstructionDictation() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "revisa el reporte y avísame el resultado antes del viernes",
            polished: "Review the report and share the result before Friday.",
            translationExpected: true
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsTranslatedOpenerThatCameFromTheSource() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "claro, hazlo cuando tengas tiempo el lunes",
            polished: "Of course, do it when you have time on Monday.",
            translationExpected: true
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testAcceptsTranslatedOpenerFromEnglishSourceIntoSpanish() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "sure, do it when you have time on monday",
            polished: "Por supuesto, hazlo cuando tengas tiempo el lunes.",
            translationExpected: true
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }

    func testRejectsIntroducedAssistantOpener() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "explícame cómo funciona el deploy",
            polished: "Claro, aquí tienes una explicación del deploy."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testRejectsIntroducedFirstPersonCompletionReport() {
        let cases = [
            (
                "prueba el modelo nuevo y anota los resultados en el reporte",
                "Ya probé el modelo nuevo y he actualizado el reporte."
            ),
            (
                "test the new model with the new harness and write the results in the report",
                "I have tested the new model and updated the report."
            ),
        ]

        for testCase in cases {
            let verdict = PolishInstructionResponseGuard.evaluate(
                raw: testCase.0,
                polished: testCase.1,
                compactionExpected: true
            )
            XCTAssertFalse(verdict.isAcceptable, testCase.0)
        }
    }

    func testRejectsIntroducedSignOff() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "revisa el reporte del sprint",
            polished: "Revisa el reporte del sprint. Espero que te sirva."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testRejectsSummaryOfWorkFramedAsRequested() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "actualiza el readme con los pasos del deploy",
            polished: "Actualicé el readme con los pasos del deploy, como me pediste."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testRejectsReplyShapedAnswerToADictatedQuestion() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "¿el deploy del viernes ya está listo?",
            polished: "Sí, el deploy del viernes ya está listo y el servicio quedó estable."
        )
        XCTAssertFalse(verdict.isAcceptable)
    }

    func testRejectsIntroducedRefusalOrApology() {
        let cases = [
            ("investiga WebRTC y dime las fuentes", "Lo siento, no puedo acceder a internet."),
            ("resume el documento de arquitectura para el equipo", "No puedo resumir documentos que no me diste."),
            ("research WebRTC and list the sources", "I'm sorry, I can't help with that request."),
            ("summarize the architecture document for the team", "As an AI, I am unable to read your files."),
        ]

        for testCase in cases {
            let verdict = PolishInstructionResponseGuard.evaluate(raw: testCase.0, polished: testCase.1)
            XCTAssertFalse(verdict.isAcceptable, testCase.1)
        }
    }

    func testAcceptsRefusalWordingThatCameFromTheSource() {
        let cases = [
            (
                "lo siento pero no puedo ayudar con la mudanza el sábado",
                "Lo siento, pero no puedo ayudar con la mudanza el sábado."
            ),
            (
                "i'm sorry i can't help with the migration this week",
                "I'm sorry, I can't help with the migration this week."
            ),
        ]

        for testCase in cases {
            let verdict = PolishInstructionResponseGuard.evaluate(raw: testCase.0, polished: testCase.1)
            XCTAssertTrue(verdict.isAcceptable, testCase.1)
        }
    }

    func testAcceptsMarkersThatCameFromTheSourceItself() {
        let verdict = PolishInstructionResponseGuard.evaluate(
            raw: "claro, ya probé el harness, entonces actualiza el reporte con eso",
            polished: "Claro, ya probé el harness; actualiza el reporte con eso."
        )
        XCTAssertTrue(verdict.isAcceptable, verdict.diagnosticSummary)
    }
}
