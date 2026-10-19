//
//  MLXModelFolderIsolationTests.swift
//  SapoWhisperTests
//
//  Per-tier folder isolation of WhisperModelDownloader against fake snapshots
//  under a temporary root — detection, deletion, and size must never
//  cross-match between tiers. Never touches the real Application Support.
//

import Foundation
import MLXWhisper
@testable import SapoWhisper
import XCTest

final class MLXModelFolderIsolationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MLXModelFolderIsolationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Fake snapshot satisfying the downloader's "downloaded" contract:
    /// non-empty weights + parseable config + every tokenizer asset present
    /// and non-empty. Weights are sized from the repo id so every tier has a
    /// distinct sizeOnDisk.
    private func makeFakeSnapshot(repo: String, root: URL) throws {
        let dir = WhisperModelDownloader.modelDirectory(repo: repo, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 64 + repo.utf8.count)
            .write(to: dir.appendingPathComponent("weights.safetensors"))
        try Data(#"{"vocab_size":51866}"#.utf8)
            .write(to: dir.appendingPathComponent("config.json"))
        for asset in WhisperModelDownloader.tokenizerAssetFiles {
            try Data(#"{"model":{}}"#.utf8).write(to: dir.appendingPathComponent(asset))
        }
    }

    private func subRoot(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Detection

    func testModelDirectoryPathsAreUniqueAcrossAllTiers() {
        let paths = MLXWhisperModel.allCases.map {
            WhisperModelDownloader.modelDirectory(repo: $0.rawValue, root: root).path
        }
        XCTAssertEqual(Set(paths).count, MLXWhisperModel.allCases.count, "tier directories must not collide")
    }

    func testDetectionMatchesOnlyTheCreatedTier() throws {
        for created in MLXWhisperModel.allCases {
            let tierRoot = try subRoot("detect-\(created.rawValue.replacingOccurrences(of: "/", with: "_"))")
            try makeFakeSnapshot(repo: created.rawValue, root: tierRoot)

            for candidate in MLXWhisperModel.allCases {
                XCTAssertEqual(
                    WhisperModelDownloader.isDownloaded(repo: candidate.rawValue, root: tierRoot),
                    candidate == created,
                    "created=\(created.rawValue) candidate=\(candidate.rawValue)"
                )
            }
        }
    }

    // MARK: - Deletion isolation

    func testDeletingOneTierNeverTouchesTheOthers() throws {
        for deleted in MLXWhisperModel.allCases {
            let tierRoot = try subRoot("delete-\(deleted.rawValue.replacingOccurrences(of: "/", with: "_"))")
            for model in MLXWhisperModel.allCases {
                try makeFakeSnapshot(repo: model.rawValue, root: tierRoot)
            }
            let sizesBefore = Dictionary(
                uniqueKeysWithValues: MLXWhisperModel.allCases.map {
                    ($0, WhisperModelDownloader.sizeOnDisk(repo: $0.rawValue, root: tierRoot))
                })

            try WhisperModelDownloader.delete(repo: deleted.rawValue, root: tierRoot)

            XCTAssertFalse(
                WhisperModelDownloader.isDownloaded(repo: deleted.rawValue, root: tierRoot),
                "deleted=\(deleted.rawValue) still detected"
            )
            for survivor in MLXWhisperModel.allCases where survivor != deleted {
                XCTAssertTrue(
                    WhisperModelDownloader.isDownloaded(repo: survivor.rawValue, root: tierRoot),
                    "deleted=\(deleted.rawValue) took survivor=\(survivor.rawValue) with it"
                )
                XCTAssertEqual(
                    WhisperModelDownloader.sizeOnDisk(repo: survivor.rawValue, root: tierRoot),
                    sizesBefore[survivor],
                    "deleted=\(deleted.rawValue) changed size of survivor=\(survivor.rawValue)"
                )
            }
        }
    }

    /// Regression (lesson sapowhisper-model-variant-substring-crossmatch):
    /// "…whisper-large-v3-turbo" is an exact prefix of "…-turbo-8bit", so any
    /// substring/prefix matching cross-hits them — assert both directions.
    func testTurboAndTurbo8BitNeverCrossMatch() throws {
        let turbo = MLXWhisperModel.largeV3Turbo.rawValue
        let turbo8Bit = MLXWhisperModel.largeV3TurboQ8.rawValue

        let onlyTurbo = try subRoot("prefix-only-turbo")
        try makeFakeSnapshot(repo: turbo, root: onlyTurbo)
        XCTAssertTrue(WhisperModelDownloader.isDownloaded(repo: turbo, root: onlyTurbo))
        XCTAssertFalse(
            WhisperModelDownloader.isDownloaded(repo: turbo8Bit, root: onlyTurbo),
            "turbo snapshot must not satisfy the 8-bit tier"
        )

        let onlyTurbo8Bit = try subRoot("prefix-only-8bit")
        try makeFakeSnapshot(repo: turbo8Bit, root: onlyTurbo8Bit)
        XCTAssertTrue(WhisperModelDownloader.isDownloaded(repo: turbo8Bit, root: onlyTurbo8Bit))
        XCTAssertFalse(
            WhisperModelDownloader.isDownloaded(repo: turbo, root: onlyTurbo8Bit),
            "8-bit snapshot must not satisfy the turbo tier"
        )

        let both = try subRoot("prefix-both")
        try makeFakeSnapshot(repo: turbo, root: both)
        try makeFakeSnapshot(repo: turbo8Bit, root: both)

        try WhisperModelDownloader.delete(repo: turbo, root: both)
        XCTAssertFalse(WhisperModelDownloader.isDownloaded(repo: turbo, root: both))
        XCTAssertTrue(
            WhisperModelDownloader.isDownloaded(repo: turbo8Bit, root: both),
            "deleting turbo must leave the 8-bit snapshot intact"
        )

        try makeFakeSnapshot(repo: turbo, root: both)
        try WhisperModelDownloader.delete(repo: turbo8Bit, root: both)
        XCTAssertFalse(WhisperModelDownloader.isDownloaded(repo: turbo8Bit, root: both))
        XCTAssertTrue(
            WhisperModelDownloader.isDownloaded(repo: turbo, root: both),
            "deleting the 8-bit tier must leave the turbo snapshot intact"
        )
    }

    // MARK: - Incomplete snapshots

    func testZeroByteWeightsAreNotDownloaded() throws {
        let model = MLXWhisperModel.largeV3TurboQ8
        let dir = WhisperModelDownloader.modelDirectory(repo: model.rawValue, root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("weights.safetensors"))
        try Data(#"{"vocab_size":51866}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data(#"{"model":{}}"#.utf8).write(to: dir.appendingPathComponent("tokenizer.json"))

        XCTAssertFalse(WhisperModelDownloader.isDownloaded(repo: model.rawValue, root: root))
    }

    func testMissingTokenizerIsNotDownloaded() throws {
        let model = MLXWhisperModel.largeV3Turbo
        try makeFakeSnapshot(repo: model.rawValue, root: root)
        let dir = WhisperModelDownloader.modelDirectory(repo: model.rawValue, root: root)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("tokenizer.json"))

        XCTAssertFalse(WhisperModelDownloader.isDownloaded(repo: model.rawValue, root: root))
    }

    /// The tokenizer prefetch is the reserved last 2% of a download and
    /// `download` early-returns on `isDownloaded`. Accepting a partial
    /// prefetch leaves the tier reporting "downloaded" forever while the
    /// loader dies, and retrying is a no-op.
    func testAnyMissingTokenizerAssetIsNotDownloaded() throws {
        let model = MLXWhisperModel.largeV3Turbo
        for asset in WhisperModelDownloader.tokenizerAssetFiles {
            let tierRoot = try subRoot("partial-missing-\(asset)")
            try makeFakeSnapshot(repo: model.rawValue, root: tierRoot)
            let dir = WhisperModelDownloader.modelDirectory(repo: model.rawValue, root: tierRoot)
            try FileManager.default.removeItem(at: dir.appendingPathComponent(asset))

            XCTAssertFalse(
                WhisperModelDownloader.isDownloaded(repo: model.rawValue, root: tierRoot),
                "missing \(asset) must not count as a complete snapshot"
            )
        }
    }

    func testZeroByteTokenizerAssetIsNotDownloaded() throws {
        let model = MLXWhisperModel.largeV3Turbo
        for asset in WhisperModelDownloader.tokenizerAssetFiles {
            let tierRoot = try subRoot("partial-empty-\(asset)")
            try makeFakeSnapshot(repo: model.rawValue, root: tierRoot)
            let dir = WhisperModelDownloader.modelDirectory(repo: model.rawValue, root: tierRoot)
            try Data().write(to: dir.appendingPathComponent(asset))

            XCTAssertFalse(
                WhisperModelDownloader.isDownloaded(repo: model.rawValue, root: tierRoot),
                "zero-byte \(asset) must not count as a complete snapshot"
            )
        }
    }
}
