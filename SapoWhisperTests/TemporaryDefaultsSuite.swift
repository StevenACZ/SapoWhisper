import Foundation

func temporaryDefaultsSuite() -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SapoWhisperTests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(UUID().uuidString).path
}
