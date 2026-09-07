import Foundation
import XCTest

@testable import MLXWhisper

@MainActor
final class WhisperFileDownloadTests: XCTestCase {
    private final class FixtureProtocol: URLProtocol {
        nonisolated(unsafe) private static var handlers: [String: @Sendable (FixtureProtocol) -> Void] = [:]
        private static let lock = NSLock()

        static func register(_ url: URL, handler: @escaping @Sendable (FixtureProtocol) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            handlers[url.absoluteString] = handler
        }

        static func remove(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            handlers.removeValue(forKey: url.absoluteString)
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func stopLoading() {}

        override func startLoading() {
            Self.lock.lock()
            let handler = Self.handlers[request.url?.absoluteString ?? ""]
            Self.lock.unlock()
            guard let handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            handler(self)
        }

        func respond(status: Int = 200, headers: [String: String], body: Data, finish: Bool = true) {
            var responseHeaders = headers
            responseHeaders["Content-Type"] = "application/octet-stream"
            responseHeaders["X-Content-Type-Options"] = "nosniff"
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: responseHeaders
            )!
            XCTAssertEqual(response.mimeType, "application/octet-stream")
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            if finish { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        return configuration
    }

    private func fixture() throws -> (root: URL, destination: URL, remote: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("weights.safetensors"), URL(string: "https://fixture.test/\(UUID())")!)
    }

    func testIntermediateProgressCancellationAndByteExactRangeResume() async throws {
        let fixture = try fixture()
        defer {
            FixtureProtocol.remove(fixture.remote)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let body = Data((0..<128).map(UInt8.init))
        let prefix = Data(body.prefix(32))
        let partial = fixture.destination.appendingPathExtension("partial")
        let progress = expectation(description: "Bytes reported while response is still open")
        FixtureProtocol.register(fixture.remote) { request in
            XCTAssertNil(request.request.value(forHTTPHeaderField: "Range"))
            request.respond(headers: ["Content-Length": "128"], body: prefix, finish: false)
        }
        let downloader = WhisperFileDownload(destination: fixture.destination, expectedSize: 128) { bytes in
            if bytes == 32 { progress.fulfill() }
        }
        let configuration = configuration()
        let task = Task { try await downloader.download(from: fixture.remote, configuration: configuration) }
        defer { task.cancel() }
        await fulfillment(of: [progress], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try Data(contentsOf: partial), prefix)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancellation must fail the active transfer")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: partial), prefix)
        let resumedRequest = expectation(description: "Resume starts at the retained byte count")
        FixtureProtocol.register(fixture.remote) { request in
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Range"), "bytes=32-")
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
            resumedRequest.fulfill()
            request.respond(
                status: 206, headers: ["Content-Length": "96", "Content-Range": "bytes 32-127/128"],
                body: Data(body.dropFirst(32)))
        }
        let resumed = WhisperFileDownload(destination: fixture.destination, expectedSize: 128) { _ in }
        try await resumed.download(from: fixture.remote, configuration: configuration)
        await fulfillment(of: [resumedRequest], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testLateFullResponseAfterCancellationPreservesRetainedPartial() async throws {
        let fixture = try fixture()
        defer {
            FixtureProtocol.remove(fixture.remote)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let partial = fixture.destination.appendingPathExtension("partial")
        let retained = Data((0..<32).map(UInt8.init))
        try retained.write(to: partial)
        let started = expectation(description: "Range request started without a response")
        FixtureProtocol.register(fixture.remote) { request in
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Range"), "bytes=32-")
            started.fulfill()
        }
        let downloader = WhisperFileDownload(destination: fixture.destination, expectedSize: 128) { _ in }
        let configuration = configuration()
        let task = Task { try await downloader.download(from: fixture.remote, configuration: configuration) }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancellation must finish before the late response")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: partial), retained)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let dummyTask = session.dataTask(with: fixture.remote)
        let response = HTTPURLResponse(
            url: fixture.remote, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "128", "Content-Type": "application/octet-stream"]
        )!
        let rejected = expectation(description: "Late response rejected after cancellation")
        downloader.urlSession(session, dataTask: dummyTask, didReceive: response) { disposition in
            XCTAssertEqual(disposition, .cancel)
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 3)
        XCTAssertEqual(try Data(contentsOf: partial), retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testServerIgnoringRangeRestartsWithoutDuplicateBytes() async throws {
        let fixture = try fixture()
        defer {
            FixtureProtocol.remove(fixture.remote)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let body = Data((0..<128).map(UInt8.init))
        let partial = fixture.destination.appendingPathExtension("partial")
        try Data(repeating: 255, count: 32).write(to: partial)
        FixtureProtocol.register(fixture.remote) { request in
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Range"), "bytes=32-")
            request.respond(headers: ["Content-Length": "128"], body: body)
        }
        let downloader = WhisperFileDownload(destination: fixture.destination, expectedSize: 128) { _ in }
        try await downloader.download(from: fixture.remote, configuration: configuration())
        XCTAssertEqual(try Data(contentsOf: fixture.destination), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testInvalidContentRangesNeverPublishDestinationOrChangeRetainedBytes() async throws {
        for range in ["bytes 0-127/128", "bytes 32-126/128", "bytes 32-127/129", "invalid"] {
            let fixture = try fixture()
            defer {
                FixtureProtocol.remove(fixture.remote)
                try? FileManager.default.removeItem(at: fixture.root)
            }
            let partial = fixture.destination.appendingPathExtension("partial")
            let retained = Data(repeating: 7, count: 32)
            try retained.write(to: partial)
            FixtureProtocol.register(fixture.remote) { request in
                request.respond(
                    status: 206, headers: ["Content-Length": "96", "Content-Range": range],
                    body: Data(repeating: 8, count: 96))
            }
            let downloader = WhisperFileDownload(destination: fixture.destination, expectedSize: 128) { _ in }
            do {
                try await downloader.download(from: fixture.remote, configuration: configuration())
                XCTFail("Invalid Content-Range must fail: \(range)")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertEqual(try Data(contentsOf: partial), retained)
        }
    }

    func testTruncatedResponseNeverPublishesDestination() async throws {
        let fixture = try fixture()
        defer {
            FixtureProtocol.remove(fixture.remote)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let body = Data(repeating: 9, count: 31)
        FixtureProtocol.register(fixture.remote) { request in
            request.respond(headers: ["Content-Length": "128"], body: body)
        }
        let downloader = WhisperFileDownload(destination: fixture.destination, expectedSize: 128) { _ in }
        do {
            try await downloader.download(from: fixture.remote, configuration: configuration())
            XCTFail("A clean EOF before all expected bytes must fail")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try Data(contentsOf: fixture.destination.appendingPathExtension("partial")), body)
    }
}
