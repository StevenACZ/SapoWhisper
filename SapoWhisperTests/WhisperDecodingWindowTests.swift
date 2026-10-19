@testable import MLXWhisper
import XCTest

@MainActor
final class WhisperDecodingWindowTests: XCTestCase {
    func testInitialWindowsCoverThirtyMinutesAndTailExactlyOnce() throws {
        let sampleCount = 30 * 60 * 16_000 + 12_347
        let windows = WhisperDecodingWindow.initial(samples: tone(count: sampleCount))

        assertExactCoverage(windows, of: 0..<sampleCount)
        XCTAssertTrue(windows.allSatisfy { $0.range.count <= 480_000 })
        XCTAssertTrue(windows.dropLast().allSatisfy { $0.range.count >= 320_000 })
        XCTAssertTrue(windows.allSatisfy { $0.retryDepth == 0 })
    }

    func testInitialWindowsKeepThirtySecondsWhole() throws {
        let exact = WhisperDecodingWindow.initial(samples: tone(count: 480_000))
        XCTAssertEqual(exact.count, 1)
        assertExactCoverage(exact, of: 0..<480_000)

        let withTail = WhisperDecodingWindow.initial(samples: tone(count: 480_001))
        XCTAssertEqual(withTail.count, 2)
        assertExactCoverage(withTail, of: 0..<480_001)
        XCTAssertTrue(withTail.allSatisfy { $0.range.count <= 480_000 })
    }

    func testLongAudioIsCutInsideTheQuietestPause() throws {
        var samples = tone(count: 50 * 16_000)
        let pause = (23 * 16_000)..<(23 * 16_000 + 8_000)
        for index in pause { samples[index] = 0 }

        let windows = WhisperDecodingWindow.initial(samples: samples)

        XCTAssertEqual(windows.count, 2)
        assertExactCoverage(windows, of: 0..<samples.count)
        let cut = try XCTUnwrap(windows.first).range.upperBound
        XCTAssertTrue(pause.contains(cut), "cut \(cut) is outside the pause \(pause)")
    }

    func testOddOffsetWindowSplitsWithoutLosingOrDuplicatingSamples() throws {
        let parent = WhisperDecodingWindow(range: 12_347..<492_346)
        let children = try parent.splitAfterOutputLimit()

        XCTAssertEqual(children.count, 2)
        assertExactCoverage(children, of: parent.range)
        XCTAssertTrue(children.allSatisfy { $0.retryDepth == parent.retryDepth + 1 })
        XCTAssertTrue(children.allSatisfy { $0.range.count >= 16_000 })
        let first = try XCTUnwrap(children.first)
        let last = try XCTUnwrap(children.last)
        XCTAssertEqual(abs(first.range.count - last.range.count), 1)
    }

    func testRetryTreeStopsAtDepthTwoWithExplicitOutputLimit() throws {
        let parent = WhisperDecodingWindow(range: 0..<480_000)
        let firstRetry = try parent.splitAfterOutputLimit()
        let secondRetry = try firstRetry.flatMap { try $0.splitAfterOutputLimit() }

        XCTAssertEqual(firstRetry.count, 2)
        XCTAssertTrue(firstRetry.allSatisfy { $0.retryDepth == 1 })
        XCTAssertEqual(secondRetry.count, 4)
        XCTAssertTrue(secondRetry.allSatisfy { $0.retryDepth == 2 })
        assertExactCoverage(secondRetry, of: parent.range)
        for window in secondRetry {
            assertOutputLimit(window)
        }
    }

    func testSplittingKeepsTheFailedGlossaryDisabled() throws {
        let parent = WhisperDecodingWindow(range: 0..<480_000, usesInitialPrompt: false)
        let children = try parent.splitAfterOutputLimit()
        let grandchildren = try children.flatMap { try $0.splitAfterOutputLimit() }
        XCTAssertTrue(children.allSatisfy { !$0.usesInitialPrompt })
        XCTAssertTrue(grandchildren.allSatisfy { !$0.usesInitialPrompt })
        assertExactCoverage(grandchildren, of: parent.range)
    }

    func testShortAudioCannotSplitBelowOneSecondPerChild() throws {
        for sampleCount in [1, 15_999, 16_000, 31_999] {
            let windows = WhisperDecodingWindow.initial(samples: tone(count: sampleCount))
            XCTAssertEqual(windows.count, 1)
            let window = try XCTUnwrap(windows.first)
            assertExactCoverage(windows, of: 0..<sampleCount)
            assertOutputLimit(window)
        }

        let minimum = WhisperDecodingWindow(range: 37..<32_037)
        let children = try minimum.splitAfterOutputLimit()
        XCTAssertEqual(children.count, 2)
        XCTAssertTrue(children.allSatisfy { $0.range.count == 16_000 })
        assertExactCoverage(children, of: minimum.range)
        for child in children {
            assertOutputLimit(child)
        }
    }

    private func tone(count: Int) -> [Float] {
        (0..<count).map { 0.2 * sin(Float($0) * 0.0785) }
    }

    private func assertExactCoverage(
        _ windows: [WhisperDecodingWindow],
        of range: Range<Int>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(windows.first?.range.lowerBound, range.lowerBound, file: file, line: line)
        XCTAssertEqual(windows.last?.range.upperBound, range.upperBound, file: file, line: line)
        XCTAssertTrue(windows.allSatisfy { !$0.range.isEmpty }, file: file, line: line)
        XCTAssertEqual(windows.reduce(0) { $0 + $1.range.count }, range.count, file: file, line: line)
        for (previous, next) in zip(windows, windows.dropFirst()) {
            XCTAssertEqual(previous.range.upperBound, next.range.lowerBound, file: file, line: line)
        }
    }

    private func assertOutputLimit(
        _ window: WhisperDecodingWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try window.splitAfterOutputLimit(), file: file, line: line) { error in
            guard let decodingError = error as? WhisperDecodingError,
                case .outputLimit = decodingError
            else {
                XCTFail("Expected WhisperDecodingError.outputLimit, received \(error)", file: file, line: line)
                return
            }
        }
    }
}
