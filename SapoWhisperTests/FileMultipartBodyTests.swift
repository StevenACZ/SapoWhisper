import XCTest

@testable import SapoWhisper

@MainActor
final class FileMultipartBodyTests: XCTestCase {
    private var directory: URL!
    private var source: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("source.wav")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testMultipartBytesAcrossMultipleCopyChunksAndPrivatePermissions() throws {
        let audio = Data((0..<(2 * 1_048_576 + 137)).map { UInt8($0 % 251) })
        try audio.write(to: source)
        let body = try FileMultipartBody.create(
            audioURL: source,
            fields: [("model", "fixture-model"), ("prompt", "first\r\nsecond")],
            boundary: "FixtureBoundary", directory: directory
        )
        defer { body.remove() }
        var expected = Data(
            ("--FixtureBoundary\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nfixture-model\r\n"
                + "--FixtureBoundary\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\nfirst  second\r\n"
                + "--FixtureBoundary\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n"
                + "Content-Type: audio/wav\r\n\r\n").utf8)
        expected.append(audio)
        expected.append(Data("\r\n--FixtureBoundary--\r\n".utf8))

        XCTAssertEqual(try Data(contentsOf: body.fileURL), expected)
        XCTAssertEqual(body.audioByteCount, audio.count)
        XCTAssertEqual(try Data(contentsOf: source), audio)
        let attributes = try FileManager.default.attributesOfItem(atPath: body.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        body.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCancellationAfterFirstChunkRemovesPartialBodyAndPreservesSource() throws {
        let audio = Data(repeating: 0x35, count: 2 * 1_048_576 + 1)
        try audio.write(to: source)
        let directory = try XCTUnwrap(directory)
        var checks = 0
        var partialBodyObserved = false
        XCTAssertThrowsError(
            try FileMultipartBody.create(
                audioURL: source, fields: [], boundary: "Cancellation", directory: directory,
                checkCancellation: {
                    checks += 1
                    if checks == 3 {
                        let partial = try XCTUnwrap(
                            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                                .first { $0.pathExtension == "body" }
                        )
                        let size = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
                        partialBodyObserved = (size?.intValue ?? 0) >= 1_048_576
                        throw CancellationError()
                    }
                }
            )
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(partialBodyObserved)
        XCTAssertTrue(try multipartFiles().isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), audio)
    }

    func testReadFailureRemovesPartialBodyAndLeavesSourceDirectoryUntouched() throws {
        let unreadableAudio = directory.appendingPathComponent("directory-source.wav")
        try FileManager.default.createDirectory(at: unreadableAudio, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try FileMultipartBody.create(audioURL: unreadableAudio, fields: [], boundary: "ReadFailure", directory: directory)
        )
        XCTAssertTrue(try multipartFiles().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadableAudio.path))
    }

    func testAlreadyCancelledTaskCreatesNoBody() async throws {
        try Data([1, 2, 3]).write(to: source)
        let source = try XCTUnwrap(source)
        let directory = try XCTUnwrap(directory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try FileMultipartBody.create(audioURL: source, fields: [], boundary: "Cancelled", directory: directory)
        }
        do {
            let body = try await task.value
            body.remove()
            XCTFail("Cancelled preparation must not return a body")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(try multipartFiles().isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    func testEachBodyHasIndependentOwnership() throws {
        try Data([1, 2, 3]).write(to: source)
        let first = try FileMultipartBody.create(audioURL: source, fields: [], boundary: "First", directory: directory)
        defer { first.remove() }
        let second = try FileMultipartBody.create(audioURL: source, fields: [], boundary: "Second", directory: directory)
        defer { second.remove() }
        XCTAssertNotEqual(first.fileURL, second.fileURL)
        first.remove()
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
    }

    private func multipartFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "body" }
    }
}
