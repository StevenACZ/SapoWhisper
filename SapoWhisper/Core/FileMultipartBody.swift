import Darwin
import Foundation

nonisolated struct FileMultipartBody: Sendable {
    static let copyChunkBytes = 1_048_576

    let fileURL: URL
    let audioByteCount: Int

    static func create(
        audioURL: URL,
        fields: [(name: String, value: String)],
        boundary: String,
        directory: URL = TemporaryAudioStorage.directory,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> FileMultipartBody {
        try checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fileURL = directory.appendingPathComponent("multipart_\(UUID().uuidString).body")
        let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var completed = false
        defer {
            try? output.close()
            if !completed { try? fileManager.removeItem(at: fileURL) }
        }
        let input = try FileHandle(forReadingFrom: audioURL)
        defer { try? input.close() }

        for field in fields {
            try checkCancellation()
            let value = field.value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            try output.write(
                contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        try output.write(
            contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
                    .utf8))
        var audioByteCount = 0
        while true {
            try checkCancellation()
            let copied = try autoreleasepool {
                guard let chunk = try input.read(upToCount: copyChunkBytes), !chunk.isEmpty else { return 0 }
                try output.write(contentsOf: chunk)
                return chunk.count
            }
            guard copied > 0 else { break }
            audioByteCount += copied
        }
        try checkCancellation()
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.close()
        try checkCancellation()
        completed = true
        return FileMultipartBody(fileURL: fileURL, audioByteCount: audioByteCount)
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
