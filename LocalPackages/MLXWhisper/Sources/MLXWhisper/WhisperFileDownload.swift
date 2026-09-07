import Foundation

final class WhisperFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let partial: URL
    private let expectedSize: Int64
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var file: FileHandle?
    private var received: Int64 = 0
    private var cancelled = false
    private var failure: Error?
    private var lastReport = Date.distantPast

    init(destination: URL, expectedSize: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.partial = destination.appendingPathExtension("partial")
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func download(from url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = Int64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if size == expectedSize, expectedSize > 0 {
            try FileManager.default.moveItem(at: partial, to: destination)
            progress(size)
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                if cancelled {
                    self.continuation = nil
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                received = size < expectedSize ? size : 0
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if received > 0 { request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range") }
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        do {
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            switch http.statusCode {
            case 200:
                received = 0
            case 206:
                let required = "bytes \(received)-\(expectedSize - 1)/\(expectedSize)"
                guard http.value(forHTTPHeaderField: "Content-Range") == required else {
                    throw URLError(.badServerResponse)
                }
            default:
                throw URLError(.badServerResponse)
            }
            if response.expectedContentLength >= 0,
                response.expectedContentLength != expectedSize - received
            {
                throw URLError(.badServerResponse)
            }
            if !FileManager.default.fileExists(atPath: partial.path) {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: partial)
            file = handle
            try handle.truncate(atOffset: UInt64(received))
            try handle.seek(toOffset: UInt64(received))
            let count = received
            lock.unlock()
            progress(count)
            completionHandler(.allow)
        } catch {
            failure = error
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do {
            guard !cancelled, failure == nil else {
                lock.unlock()
                return
            }
            guard let file, received + Int64(data.count) <= expectedSize else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            try file.write(contentsOf: data)
            received += Int64(data.count)
            let count = received
            let report = Date().timeIntervalSince(lastReport) >= 0.1 || count == expectedSize
            if report { lastReport = Date() }
            lock.unlock()
            if report { progress(count) }
        } catch {
            failure = error
            lock.unlock()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        var result: Result<Void, Error>
        do {
            try file?.close()
            file = nil
            if cancelled { throw CancellationError() }
            if let failure { throw failure }
            if let error { throw error }
            guard received == expectedSize else { throw URLError(.networkConnectionLost) }
            try FileManager.default.moveItem(at: partial, to: destination)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
