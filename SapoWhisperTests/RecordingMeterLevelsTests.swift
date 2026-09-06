import XCTest

@testable import SapoWhisper

@MainActor
final class RecordingMeterLevelsTests: XCTestCase {
    func testSpeechPowerRemainsDistinctThroughLoudInput() {
        let levels = [-36.0, -24, -18, -12, -6].map { decibels in
            RecordingMeterLevels.advance(CGFloat((decibels + 60) / 60), previous: Array(repeating: 0, count: 11))[5]
        }
        XCTAssertTrue(zip(levels, levels.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertGreaterThan(levels[0], 0)
        XCTAssertLessThan(levels[4], 1)
        XCTAssertEqual(RecordingMeterLevels.advance(1, previous: [0])[0], 1, accuracy: 0.0001)
    }

    func testSilenceClearsEveryBarWithinFourInputUpdates() {
        var levels = Array(repeating: CGFloat(1), count: 11)
        for _ in 0..<4 { levels = RecordingMeterLevels.advance(0, previous: levels) }
        XCTAssertEqual(levels, Array(repeating: 0, count: 11))
        XCTAssertEqual(RecordingMeterLevels.advance(0, previous: levels), levels)
    }

    func testQuietInputAndInvalidSamplesStayAtBaseline() {
        for input in [CGFloat(0), 0.2, 0.27, -.infinity, .infinity, .nan] {
            XCTAssertEqual(RecordingMeterLevels.advance(input, previous: [0]), [0])
        }
        XCTAssertTrue(RecordingMeterLevels.advance(0.8, previous: []).isEmpty)
    }
}
