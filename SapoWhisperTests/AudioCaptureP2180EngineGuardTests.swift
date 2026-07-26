//
//  AudioCaptureP2180EngineGuardTests.swift
//  SapoWhisperTests
//
//  P2-180: AVFAudio teardown (removeTap / stop / reset) raises uncatchable
//  Objective-C exceptions mid route change, so every occurrence in the capture
//  engine must sit inside an AudioEngineGuard block. The crash itself needs a
//  real route transition, so the rule is enforced as a source invariant.
//

import Foundation
import XCTest

@testable import SapoWhisper

final class AudioCaptureP2180EngineGuardTests: XCTestCase {

    private static let teardownCalls = ["removeTap(onBus:", ".stop()", ".reset()"]

    private static var captureEngineSources: [URL] {
        let coreDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SapoWhisper")
            .appendingPathComponent("Core")
        let contents = (try? FileManager.default.contentsOfDirectory(at: coreDirectory, includingPropertiesForKeys: nil)) ?? []
        return
            contents
            .filter { $0.lastPathComponent.hasPrefix("AudioCaptureEngine") && $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testCaptureEngineSourcesAreReachable() {
        XCTAssertEqual(
            Self.captureEngineSources.map(\.lastPathComponent),
            [
                "AudioCaptureEngine+Device.swift",
                "AudioCaptureEngine+Diagnostics.swift",
                "AudioCaptureEngine+Processing.swift",
                "AudioCaptureEngine.swift",
            ]
        )
    }

    func testEveryEngineTeardownRunsInsideAudioEngineGuard() throws {
        var violations: [String] = []
        for source in Self.captureEngineSources {
            let text = try String(contentsOf: source, encoding: .utf8)
            violations += Self.unguardedTeardowns(in: text, file: source.lastPathComponent)
        }

        XCTAssertEqual(violations, [], "AVAudioEngine teardown outside AudioEngineGuard at \(violations.joined(separator: ", "))")
    }

    func testTheDetectorFlagsAnUnguardedTeardown() {
        let unguarded = """
            func teardown(engine: AVAudioEngine) {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            """
        let guarded = """
            func teardown(engine: AVAudioEngine) {
                try? AudioEngineGuard.run("teardown") {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
            }
            """

        XCTAssertEqual(Self.unguardedTeardowns(in: unguarded, file: "Stub.swift"), ["Stub.swift:2", "Stub.swift:3"])
        XCTAssertEqual(Self.unguardedTeardowns(in: guarded, file: "Stub.swift"), [])
    }

    private static func unguardedTeardowns(in text: String, file: String) -> [String] {
        var violations: [String] = []
        var depth = 0
        var guardDepths: [Int] = []

        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = strippingComment(rawLine)
            let opensGuard = line.contains("AudioEngineGuard.")
            let guarded = opensGuard || guardDepths.contains { depth > $0 }

            if !guarded, teardownCalls.contains(where: { line.contains($0) }) {
                violations.append("\(file):\(index + 1)")
            }

            if opensGuard, line.contains("{") {
                guardDepths.append(depth)
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            guardDepths.removeAll { depth <= $0 }
        }
        return violations
    }

    private static func strippingComment(_ line: String) -> String {
        guard let marker = line.range(of: "//") else { return line }
        return String(line[line.startIndex..<marker.lowerBound])
    }
}
