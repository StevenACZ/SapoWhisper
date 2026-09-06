//
//  PolishOutputSanitizerTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

/// The sanitizer is the single boundary between provider output and the
/// user's clipboard/paste (guards are retry-only and the last output ships
/// after the budget): control bytes, bidi overrides, and invisible
/// characters must never survive — and legitimate text must be untouched.
@MainActor
final class PolishOutputSanitizerTests: XCTestCase {

    private func clean(_ output: String, raw: String = "texto dictado") -> String {
        PolishOutputSanitizer.clean(output, rawText: raw)
    }

    func testStripsANSIEscapeBytes() {
        XCTAssertEqual(
            clean("hola \u{1B}[31mmundo\u{1B}[0m"),
            "hola [31mmundo[0m",
            "ESC must be dropped so CSI sequences cannot rewrite a terminal line"
        )
    }

    func testStripsOSCSequenceBytes() {
        XCTAssertEqual(
            clean("nota\u{1B}]52;c;cGF5bG9hZA==\u{07}final"),
            "nota]52;c;cGF5bG9hZA==final",
            "ESC and BEL must be dropped so OSC 52 cannot reach the clipboard"
        )
    }

    func testStripsBidiOverrides() {
        XCTAssertEqual(clean("factura \u{202E}021\u{202C} lista"), "factura 021 lista")
        XCTAssertEqual(clean("total \u{2066}42\u{2069}"), "total 42")
    }

    func testStripsInvisibleCharacters() {
        XCTAssertEqual(clean("cla\u{200B}ve \u{2060}dos\u{FEFF}"), "clave dos")
    }

    func testNormalizesCarriageReturns() {
        XCTAssertEqual(clean("línea uno\r\nlínea dos\rlínea tres"), "línea uno\nlínea dos\nlínea tres")
    }

    func testKeepsSpanishEmojiTabsAndNewlines() {
        let text = "¿Qué señal? café\tlisto\nfamilia 👨‍👩‍👧 ¡ya!"
        XCTAssertEqual(clean(text), text)
    }

    func testStripApplsToRawFallbackToo() {
        // A cleaned-to-empty output falls back to the original — that
        // fallback must be the sanitized original, not the raw bytes.
        let onlyWrapped = "\"\u{1B}[2Jtexto dictado\""
        XCTAssertFalse(clean(onlyWrapped).unicodeScalars.contains { $0.value == 0x1B })
    }

    // MARK: - Reasoning blocks

    func testThinkingOnlyOutputIsDroppedInsteadOfPasted() {
        XCTAssertEqual(
            clean("<think>El usuario quiere que limpie el texto. Debo responder…</think>"),
            "",
            "reasoning with no answer after it must never reach the clipboard"
        )
    }

    func testUnterminatedThinkingOutputIsDropped() {
        XCTAssertEqual(clean("<think>El usuario quiere que limpie el texto"), "")
    }

    func testThinkingBlockBeforeAnAnswerKeepsOnlyTheAnswer() {
        XCTAssertEqual(clean("<think>razono</think>\nTexto dictado limpio."), "Texto dictado limpio.")
    }

    func testComposesWithWrapperStripping() {
        XCTAssertEqual(
            clean("```\nhola\u{200B} mundo\n```"),
            "hola mundo",
            "control stripping must not break fence/preamble cleanup"
        )
    }
}
