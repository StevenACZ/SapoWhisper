//
//  ScribeVerbatimCleanupTests.swift
//  SapoWhisperTests
//

@testable import SapoWhisper
import XCTest

/// The inputs mirror the shapes Scribe verbatim produced on real dictations
/// (2026-10-13): fillers, cut-off words marked "--", stretched vowels and
/// stutters, each with the punctuation it carried.
final class ScribeVerbatimCleanupTests: XCTestCase {

    private func assertCleans(_ input: String, to expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ScribeVerbatimCleanup.clean(input), expected, file: file, line: line)
    }

    func testDropsFillersAndRecapitalizesTheSentenceStart() {
        assertCleans("Eh, bueno, vamos a ver.", to: "Bueno, vamos a ver.")
        assertCleans("Listo. Eh, vamos con eso.", to: "Listo. Vamos con eso.")
        assertCleans("Mmm, te puedo", to: "Te puedo")
        assertCleans("eee, entonces", to: "entonces")
        assertCleans("um, I think uh we should", to: "I think we should")
    }

    func testFillerPunctuationMovesToThePreviousWord() {
        assertCleans("y eso, eh. Luego", to: "y eso. Luego")
        assertCleans("el usuario... mm se le puede", to: "el usuario... se le puede")
    }

    func testDropsCutOffWordsAndStutters() {
        assertCleans("la-- la casa", to: "la casa")
        assertCleans("eso, eso es todo", to: "eso es todo")
        assertCleans("no, no, no.", to: "no.")
    }

    func testCollapsesStretchedVowels() {
        assertCleans("Holaaa, ¿qué tal?", to: "Hola, ¿qué tal?")
    }

    func testKeepsNumbersAndUnits() {
        assertCleans("4 4 5", to: "4 4 5")
        assertCleans("mide 5 mm de ancho", to: "mide 5 mm de ancho")
    }

    func testCleanTextIsReturnedUntouched() {
        let text = "Revisa el PR y avísame  cuando esté listo."
        XCTAssertEqual(ScribeVerbatimCleanup.clean(text), text)
    }

    func testOnlyFillersLeaveNothing() {
        XCTAssertEqual(ScribeVerbatimCleanup.clean("Eh... mmm."), "")
    }
}
