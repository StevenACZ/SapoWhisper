//
//  OrphanAudioRecovery.swift
//  SapoWhisper
//

import Foundation
import os

/// Launch-time recovery for recordings the app never got to persist: a crash,
/// force-quit, or power loss mid-dictation leaves the incrementally written
/// WAV in the temp directory with no History row, and the daily sweep would
/// silently delete it after 24h. This sweep turns each orphan into a failed
/// History entry (repairing the WAV header the interrupted writer left stale),
/// so the user can retranscribe it instead of losing the dictation.
nonisolated enum OrphanAudioRecovery {

    /// Only real dictation captures are recoverable; mic-test WAVs are noise.
    static let recoverablePrefixes = ["recording_", "flux_recording_"]
    /// Unmarked files newer than this could still belong to a live session.
    /// WAVs whose ActiveRecordingMarker owner died skip this gate entirely.
    static let minimumAge: TimeInterval = 60
    /// Sub-second stubs (a start that never captured speech) are not worth a row.
    static let minimumDuration: TimeInterval = 1.0
    static let failureCode = "SapoWhisper/recovered_after_crash"
    static let engineName = "Recovered"

    /// One dictation adopted into History by the recovery sweep.
    struct RecoveredRecording {
        let historyId: Int64
        let audioURL: URL
        let duration: TimeInterval
        let modifiedAt: Date
    }

    struct Result {
        var recovered: [RecoveredRecording] = []
        var count: Int { recovered.count }
        /// Most recently captured recovery — the "continue previous
        /// dictation?" offer candidate.
        var latest: RecoveredRecording? {
            recovered.max(by: { $0.modifiedAt < $1.modifiedAt })
        }
    }

    /// Scans `directory` for abandoned dictation WAVs and persists each one as
    /// a failed History row. A WAV is abandoned when its active-recording
    /// marker names a dead process (instant), or when it is unmarked and older
    /// than `minimumAge` (legacy crash paths, older app versions).
    @discardableResult
    static func recoverAbandonedRecordings(
        in directory: URL = TemporaryAudioStorage.directory,
        historyManager: TranscriptionHistoryManager = .shared,
        now: Date = Date()
    ) -> Result {
        let fileManager = FileManager.default
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else { return Result() }

        let markerAbandoned = Set(ActiveRecordingMarker.abandonedRecordings(in: directory))
        let referencedNames = Set(
            historyManager.referencedAudioPaths().map { ($0 as NSString).lastPathComponent }
        )

        var result = Result()
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".wav"), recoverablePrefixes.contains(where: name.hasPrefix) else { continue }
            guard !referencedNames.contains(name) else { continue }

            let modified =
                (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if !markerAbandoned.contains(file) {
                // No dead-owner marker: a live session may still be writing.
                guard now.timeIntervalSince(modified) > minimumAge else { continue }
            }

            guard let info = WAVHeaderRepair.repairIfNeeded(at: file) else {
                SapoLog.recording.warning("Orphan WAV skipped reason=unreadable-header")
                continue
            }
            guard info.duration >= minimumDuration else {
                SapoLog.recording.info(
                    "Orphan WAV skipped reason=too-short durationMs=\(Int(info.duration * 1000), privacy: .public)"
                )
                continue
            }

            let persisted = historyManager.persistEntry(
                audioSource: file,
                engine: engineName,
                language: "auto",
                duration: info.duration,
                text: "",
                rawText: "",
                status: "failed",
                failureCode: failureCode
            )
            guard persisted.rowID > 0 else {
                SapoLog.recording.error("Orphan WAV recovery insert failed")
                continue
            }
            var recoveredURL = file
            if persisted.copiedToHistory {
                try? fileManager.removeItem(at: file)
                if let historyPath = persisted.audioPath {
                    recoveredURL = URL(fileURLWithPath: historyPath)
                }
            }
            result.recovered.append(
                RecoveredRecording(
                    historyId: persisted.rowID,
                    audioURL: recoveredURL,
                    duration: info.duration,
                    modifiedAt: modified
                )
            )
            SapoLog.recording.info(
                "Orphan WAV recovered durationSec=\(Int(info.duration), privacy: .public) repairedHeader=\(info.repairedHeader, privacy: .public)"
            )
        }

        if result.count > 0 {
            SapoLog.recording.info("Orphan audio recovery finished recovered=\(result.count, privacy: .public)")
        }
        return result
    }
}

/// Minimal RIFF/WAVE reader-repairer. An interrupted `AVAudioFile` writer
/// leaves the RIFF and `data` chunk sizes stale (usually 0) even though the
/// samples are on disk; players and transcribers then treat the file as empty.
/// The repair recomputes both sizes from the real file length in place.
nonisolated enum WAVHeaderRepair {

    struct Info {
        let duration: TimeInterval
        let repairedHeader: Bool
    }

    /// Parses the header, patching stale chunk sizes when they disagree with
    /// the actual file length. Returns nil when the file is not a parseable
    /// WAV (leaving it untouched for the stale sweep to collect).
    static func repairIfNeeded(at url: URL) -> Info? {
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 44 else { return nil }

        func read(_ count: Int, at offset: UInt64) -> Data? {
            guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return data
        }

        func uint32(_ data: Data, _ index: Int) -> UInt32 {
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> UInt32 in
                let byte0 = UInt32(buffer[index])
                let byte1 = UInt32(buffer[index + 1]) << 8
                let byte2 = UInt32(buffer[index + 2]) << 16
                let byte3 = UInt32(buffer[index + 3]) << 24
                return byte0 | byte1 | byte2 | byte3
            }
        }

        guard let riff = read(12, at: 0),
            riff[0...3].elementsEqual("RIFF".utf8),
            riff[8...11].elementsEqual("WAVE".utf8)
        else { return nil }

        var offset: UInt64 = 12
        var byteRate: UInt32 = 0
        var dataOffset: UInt64?
        var declaredDataSize: UInt32 = 0

        while offset + 8 <= fileSize {
            guard let header = read(8, at: offset) else { return nil }
            let chunkID = header[0...3]
            let chunkSize = uint32(header, 4)

            if chunkID.elementsEqual("fmt ".utf8) {
                guard chunkSize >= 16, let fmt = read(16, at: offset + 8) else { return nil }
                byteRate = uint32(fmt, 8)
            } else if chunkID.elementsEqual("data".utf8) {
                dataOffset = offset + 8
                declaredDataSize = chunkSize
                break
            }

            // Chunks are word-aligned; a stale/absurd size would loop forever,
            // so bail out of the scan on anything past the file end.
            let padded = UInt64(chunkSize) + (chunkSize % 2 == 0 ? 0 : 1)
            let next = offset + 8 + padded
            guard next > offset, next <= fileSize else { return nil }
            offset = next
        }

        guard let dataOffset, byteRate > 0, dataOffset <= fileSize else { return nil }

        let actualDataSize = UInt32(min(UInt64(UInt32.max), fileSize - dataOffset))
        var repaired = false

        if declaredDataSize == 0 || UInt64(declaredDataSize) + dataOffset > fileSize {
            func writeUInt32(_ value: UInt32, at target: UInt64) {
                var little = value.littleEndian
                let data = withUnsafeBytes(of: &little) { Data($0) }
                if (try? handle.seek(toOffset: target)) != nil {
                    try? handle.write(contentsOf: data)
                }
            }
            writeUInt32(UInt32(min(UInt64(UInt32.max), fileSize - 8)), at: 4)
            writeUInt32(actualDataSize, at: dataOffset - 4)
            repaired = true
        }

        let effectiveDataSize = repaired ? actualDataSize : declaredDataSize
        let duration = TimeInterval(effectiveDataSize) / TimeInterval(byteRate)
        return Info(duration: duration, repairedHeader: repaired)
    }
}
