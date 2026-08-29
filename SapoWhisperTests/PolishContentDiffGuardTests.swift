//
//  PolishContentDiffGuardTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class PolishContentDiffGuardTests: XCTestCase {

    // MARK: - Digit runs

    func testSeparatorRepairIsNotALoss() {
        // STT mangles spoken numbers; the polish must stay free to fix
        // "0,63.40.64" → "0.63.40.64" (same digit runs, new separators).
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "el valor quedó en 0,63.40.64 al final",
            polished: "El valor quedó en 0.63.40.64 al final."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testStutterRunMayBeAbsorbedByLongerSurvivingRun() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "en la rama 14 ca-- eh, 1440 hicimos mejoras",
            polished: "En la rama 1440 hicimos mejoras."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testRepeatedNumberOnlyNeedsToSurviveOnce() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "ponle 12 píxeles o sea 12 píxeles de padding",
            polished: "Ponle 12 píxeles de padding."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testSeparatorRepairPreservesOneNumericOccurrence() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "el precio final es 12,50 por cada licencia",
            polished: "El precio final es 12.50 por cada licencia."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testRemovingASeparatorPreservesTheDigitRun() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "el precio final es 12.50 por cada licencia",
            polished: "El precio final es 1250 por cada licencia."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testCombinedLargerRunMaySatisfySourceRuns() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "usa 12 unidades ahora y 50 unidades después",
            polished: "Usa 1250 unidades después."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testNumericOrderDoesNotRawFallbackPolish() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "mueve 5 tickets al sprint 6",
            polished: "Mueve 6 tickets al sprint 5."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testVanishedDigitsAreALoss() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "la reunión es a las 10 y dura 3 horas",
            polished: "La reunión es a las diez y dura tres horas."
        )
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertEqual(verdict.lostDigitRuns, 2)
        XCTAssertNotNil(verdict.retryInstruction)
    }

    func testNumericSignIsLeftToPromptAndReview() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "el ajuste es -5 dólares",
            polished: "El ajuste es 5 dólares."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testDigitLossIsCheckedEvenWhenTranslationExpected() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "el deploy tarda 45 minutos",
            polished: "The deploy takes a while.",
            translationExpected: true
        )
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertEqual(verdict.lostDigitRuns, 1)
    }

    // MARK: - Content clusters

    func testDroppedPassageIsDetected() {
        // Mirrors the plain-mode collapse caught on the 2026-07-04 bench: the
        // output kept the opening sentence and silently dropped the rest.
        let raw = """
            Primero revisa la configuración del servidor porque está fallando. \
            Después necesito que actualices la documentación completa del proyecto \
            con los cambios nuevos del pipeline de despliegue continuo. También \
            avísale al equipo de infraestructura que vamos a migrar la base de \
            datos el viernes por la noche según lo acordado.
            """
        let verdict = PolishContentDiffGuard.evaluate(
            raw: raw,
            polished: "Primero revisa la configuración del servidor porque está fallando."
        )
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertGreaterThanOrEqual(verdict.droppedClusters, 1)
        XCTAssertNotNil(verdict.retryInstruction)
    }

    func testMergedRepetitionIsNotADroppedPassage() {
        // The v6 prompt merges repeated ideas; the kept copy still carries
        // the distinctive words, so no cluster reads as dropped.
        let raw = """
            Quiero que el botón de guardar funcione bien en pantallas chicas del iPhone. \
            O sea lo que digo es que el botón de guardar se vea bien en las pantallas \
            chicas del iPhone sin romperse nunca.
            """
        let verdict = PolishContentDiffGuard.evaluate(
            raw: raw,
            polished: "Quiero que el botón de guardar se vea bien en pantallas chicas del iPhone sin romperse."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testDroppedInstructionIsDetectedWhenOneWordSurvivesElsewhere() {
        let raw = """
            Revisa el estado general del cache antes del despliegue. \
            Elimina por completo el directorio temporal del cache antes de ejecutar la publicación.
            """
        let verdict = PolishContentDiffGuard.evaluate(
            raw: raw,
            polished: "Revisa el estado general del cache antes del despliegue."
        )
        XCTAssertFalse(verdict.isAcceptable)
        XCTAssertEqual(verdict.droppedClusters, 1)
    }

    func testDroppedInstructionClusterCheckRemainsExemptForCompactAndTranslation() {
        let raw = "Elimina por completo el directorio temporal del cache antes de ejecutar la publicación."
        let polished = "Publicación limpia."
        XCTAssertTrue(
            PolishContentDiffGuard.evaluate(raw: raw, polished: polished, translationExpected: true).isAcceptable)
        XCTAssertTrue(
            PolishContentDiffGuard.evaluate(raw: raw, polished: polished, compactionExpected: true).isAcceptable)
    }

    func testClusterCheckSkippedWhenTranslationExpected() {
        let raw = """
            Después necesito que actualices la documentación completa del proyecto \
            con los cambios nuevos del pipeline de despliegue continuo para el equipo.
            """
        let verdict = PolishContentDiffGuard.evaluate(
            raw: raw,
            polished: "Then I need you to update the full project documentation with the new pipeline changes for the team.",
            translationExpected: true
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testShortSentencesAreNeverClusters() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "Dale. Perfecto. Ya quedó listo todo.",
            polished: "Dale, perfecto, ya quedó listo."
        )
        XCTAssertTrue(verdict.isAcceptable)
    }

    func testCleanPolishPasses() {
        let verdict = PolishContentDiffGuard.evaluate(
            raw: "eh bueno la rama 205 sale de la 206 como se dice y ahí haces git push",
            polished: "La rama 205 sale de la 206, y ahí haces git push."
        )
        XCTAssertTrue(verdict.isAcceptable)
        XCTAssertNil(verdict.retryInstruction)
    }
}
