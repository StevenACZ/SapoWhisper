import Foundation
import XCTest

final class LogPrivacyInvariantTests: XCTestCase {
    func testSourceLogsDoNotPublishErrorTextOrFileNames() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("SapoWhisper")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        let sourceURLs = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let forbidden = [
            "localizedDescription, privacy: .public",
            "lastPathComponent, privacy: .public",
            "absoluteString, privacy: .public",
            "error=\\(message, privacy: .public)",
            "error=\\(error.localizedDescription",
            "file=\\(",
            "name=\\(",
            "localizedName ??",
        ]

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for pattern in forbidden {
                XCTAssertFalse(
                    source.contains(pattern),
                    "\(sourceURL.lastPathComponent) publishes unsafe log content: \(pattern)"
                )
            }
        }
    }
}
