import Foundation
import Testing

@Suite("Release packaging script")
struct ReleasePackagingScriptTests {
    @Test("The stapled app is packaged into the DMG")
    func stapledAppPrecedesDMGCreation() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repository.appendingPathComponent("scripts/package_notarized_dmg.sh"),
            encoding: .utf8
        )
        let activeLines = script.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        let appNotary = try lineIndex(
            "xcrun notarytool submit \"$APP_NOTARY_ARCHIVE\" --keychain-profile \"$NOTARY_PROFILE\" --wait",
            in: activeLines
        )
        let appStaple = try lineIndex("xcrun stapler staple \"$BUILT_APP\"", in: activeLines)
        let appValidate = try lineIndex("xcrun stapler validate \"$BUILT_APP\"", in: activeLines)
        let createDMG = try lineIndex(
            "create-dmg \"${DMG_ARGS[@]}\" \"$OUTPUT_DMG\" \"$BUILT_APP\"",
            in: activeLines
        )

        #expect(appNotary < appStaple)
        #expect(appStaple < appValidate)
        #expect(appValidate < createDMG)
        #expect(activeLines.contains("xcrun stapler validate \"$MOUNTED_APP\""))
    }

    private func lineIndex(_ command: String, in lines: [String]) throws -> Int {
        try #require(lines.firstIndex(of: command))
    }
}
