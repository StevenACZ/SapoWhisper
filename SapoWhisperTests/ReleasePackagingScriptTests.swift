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
        #expect(
            activeLines.contains(
                "scripts/verify_release_app.sh \"$BUILT_APP\" \"Developer ID Application\""
            )
        )
        #expect(
            activeLines.contains(
                "scripts/verify_release_app.sh \"$MOUNTED_APP\" \"Developer ID Application\""
            )
        )
    }

    @Test("Private path scanning rejects a contaminated artifact")
    func privatePathScannerRejectsContamination() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = repository.appendingPathComponent("scripts/verify_no_private_paths.sh")
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }

        try Data("safe artifact".utf8).write(to: fixture)
        #expect(try run(script, argument: fixture) == 0)

        let contaminatedPath = ["", "Users", "example", "private", "source.cpp"]
            .joined(separator: "/")
        try Data("compiled from \(contaminatedPath)".utf8).write(to: fixture)
        #expect(try run(script, argument: fixture) != 0)
    }

    @Test("The release verifier pins identity and artifact shape")
    func verifierPinsIdentityAndArtifactShape() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repository.appendingPathComponent("scripts/verify_release_app.sh"),
            encoding: .utf8
        )
        #expect(script.contains("EXPECTED_TEAM_ID=\"NXT93S55FY\""))
        #expect(script.contains("BUNDLE_ID\" != \"oli.SapoWhisper"))
        #expect(script.contains("ARCHITECTURES\" != \"arm64"))
        #expect(
            script.contains(
                "certificate leaf[subject.OU] = $EXPECTED_TEAM_ID"
            )
        )
        #expect(script.contains("scripts/verify_no_private_paths.sh"))
    }

    @Test("Sparkle archives strip and reject AppleDouble sidecars")
    func sparkleArchiveRejectsAppleDouble() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repository.appendingPathComponent("scripts/generate_appcast.sh"),
            encoding: .utf8
        )
        #expect(script.contains("COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent"))
        #expect(script.contains("unzip -Z1 \"$ZIP_PATH\" >\"$ZIP_ENTRIES\""))
        #expect(script.contains("grep -E -q '(^|/)\\._' \"$ZIP_ENTRIES\""))
        #expect(
            script.components(
                separatedBy:
                    "scripts/verify_release_app.sh \"$APP_PATH\" \"Developer ID Application\""
            ).count == 2
        )
        #expect(
            script.contains(
                "scripts/verify_release_app.sh \"$ARCHIVED_APP\" \"Developer ID Application\""
            )
        )
    }

    @Test("The public media gate rejects video containers")
    func publicMediaGateIncludesVideo() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repository.appendingPathComponent("scripts/verify_public_audio_allowlist.sh"),
            encoding: .utf8
        )
        #expect(script.contains("audio/* | video/*"))
        #expect(script.contains("*.[Mm][Oo][Vv]"))
        #expect(script.contains("*.[Mm][Pp]4"))
        #expect(script.contains("*.[Ww][Ee][Bb][Mm]"))
    }

    private func run(_ executable: URL, argument: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func lineIndex(_ command: String, in lines: [String]) throws -> Int {
        try #require(lines.firstIndex(of: command))
    }
}
