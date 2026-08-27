//
//  AudioCaptureEngineGuardTests.swift
//  SapoWhisperTests
//
//  AVFAudio teardown (removeTap / stop / reset) raises uncatchable
//  Objective-C exceptions mid route change, so every occurrence in the capture
//  engine must sit inside an AudioEngineGuard block. The crash itself needs a
//  real route transition, so the rule is enforced as a source invariant.
//

import Foundation
import XCTest

@testable import SapoWhisper

final class AudioCaptureEngineGuardTests: XCTestCase {

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

    private static var audioEngineLifecycleSources: [URL] {
        let coreDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SapoWhisper")
            .appendingPathComponent("Core")
        return captureEngineSources + [
            coreDirectory.appendingPathComponent("AudioLevelMonitor.swift"),
            coreDirectory.appendingPathComponent("Managers/AudioInputPreflightManager.swift"),
            coreDirectory.appendingPathComponent("Permissions/MicrophonePermission.swift"),
        ]
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
        for source in Self.audioEngineLifecycleSources {
            let text = try String(contentsOf: source, encoding: .utf8)
            violations += Self.unguardedTeardowns(in: text, file: source.lastPathComponent)
        }

        XCTAssertEqual(violations, [], "AVAudioEngine teardown outside AudioEngineGuard at \(violations.joined(separator: ", "))")
    }

    func testEveryTeardownCallOwnsItsGuardBlock() throws {
        var violations: [String] = []
        for source in Self.audioEngineLifecycleSources {
            let text = try String(contentsOf: source, encoding: .utf8)
            violations += Self.teardownsSharingAGuard(in: text, file: source.lastPathComponent)
        }

        XCTAssertEqual(
            violations, [],
            "a raised removeTap would skip the stop/reset sharing its guard at \(violations.joined(separator: ", "))"
        )
    }

    func testRetirementWaitsForEngineAndRouteQuiescence() {
        XCTAssertEqual(
            AudioEngineRetirementPool.releaseDelay(
                elapsedSinceRetirement: 0,
                routeSettleDelay: 0
            ),
            AudioEngineRetirementPool.quietPeriod
        )
        XCTAssertEqual(
            AudioEngineRetirementPool.releaseDelay(
                elapsedSinceRetirement: AudioEngineRetirementPool.quietPeriod + 1,
                routeSettleDelay: 1.25
            ),
            1.25
        )
        XCTAssertEqual(
            AudioEngineRetirementPool.releaseDelay(
                elapsedSinceRetirement: AudioEngineRetirementPool.quietPeriod + 1,
                routeSettleDelay: 0
            ),
            0
        )
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
        XCTAssertEqual(Self.teardownsSharingAGuard(in: guarded, file: "Stub.swift"), ["Stub.swift:4"])
        XCTAssertEqual(
            Self.teardownsSharingAGuard(
                in: """
                    try? AudioEngineGuard.run("remove-tap") {
                        engine.inputNode.removeTap(onBus: 0)
                    }
                    try? AudioEngineGuard.run("stop") { engine.stop() }
                    """,
                file: "Stub.swift"
            ),
            []
        )
    }

    private static func teardownsSharingAGuard(in text: String, file: String) -> [String] {
        var violations: [String] = []
        var depth = 0
        var openGuards: [(depth: Int, teardowns: Int)] = []

        for (index, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let line = strippingComment(rawLine)
            if line.contains("AudioEngineGuard."), line.contains("{") {
                openGuards.append((depth, 0))
            }
            if !openGuards.isEmpty, teardownCalls.contains(where: { line.contains($0) }) {
                openGuards[openGuards.count - 1].teardowns += 1
                if openGuards[openGuards.count - 1].teardowns > 1 {
                    violations.append("\(file):\(index + 1)")
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            while let last = openGuards.last, depth <= last.depth {
                openGuards.removeLast()
            }
        }
        return violations
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
