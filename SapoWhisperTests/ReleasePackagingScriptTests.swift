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
        #expect(activeLines.contains("SOURCE_IDENTITY=\"$(scripts/verify_release_inputs.sh)\""))
        #expect(
            activeLines.contains(
                "BUILT_IDENTITY=\"$(scripts/verify_release_inputs.sh --app \"$BUILT_APP\")\""
            )
        )
        #expect(
            activeLines.contains(
                "scripts/verify_release_inputs.sh --app \"$MOUNTED_APP\" >/dev/null"
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
        #expect(script.contains("scripts/verify_release_inputs.sh --app \"$APP_PATH\""))
        #expect(script.contains("scripts/verify_release_inputs.sh --app \"$ARCHIVED_APP\""))
    }

    @Test("Release inputs reject untracked and ignored synchronized files")
    func releaseInputsRejectExtraSynchronizedFiles() throws {
        let repository = try makeReleaseFixture()
        defer { try? FileManager.default.removeItem(at: repository) }
        let script = releaseInputScript()

        #expect(try run(script, arguments: ["--root", repository.path]) == 0)

        let untracked = repository.appendingPathComponent("SapoWhisper/Untracked.swift")
        try Data("let untracked = true\n".utf8).write(to: untracked)
        #expect(try run(script, arguments: ["--root", repository.path]) != 0)
        try FileManager.default.removeItem(at: untracked)

        let gitignore = repository.appendingPathComponent(".gitignore")
        try Data("SapoWhisper/Ignored.swift\n".utf8).write(to: gitignore)
        try requireSuccess("/usr/bin/git", ["add", ".gitignore"], in: repository)
        let ignored = repository.appendingPathComponent("SapoWhisper/Ignored.swift")
        try Data("let ignored = true\n".utf8).write(to: ignored)
        #expect(try run(script, arguments: ["--root", repository.path]) != 0)
    }

    @Test("Release inputs reject stale app identity")
    func releaseInputsRejectStaleAppIdentity() throws {
        let repository = try makeReleaseFixture()
        defer { try? FileManager.default.removeItem(at: repository) }
        let app = repository.appendingPathComponent("Fixture.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleShortVersionString": "2.17.0",
            "CFBundleVersion": "26",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        #expect(
            try run(
                releaseInputScript(),
                arguments: ["--root", repository.path, "--app", app.path]
            ) != 0
        )
    }

    @Test("Release inputs require one project identity")
    func releaseInputsRejectConflictingProjectIdentity() throws {
        let repository = try makeReleaseFixture()
        defer { try? FileManager.default.removeItem(at: repository) }
        let project = repository.appendingPathComponent("SapoWhisper.xcodeproj/project.pbxproj")
        let settings = """
            MARKETING_VERSION = 2.17.0;
            CURRENT_PROJECT_VERSION = 27;
            MARKETING_VERSION = 2.18.0;
            CURRENT_PROJECT_VERSION = 27;
            """
        try Data(settings.utf8).write(to: project)

        #expect(try run(releaseInputScript(), arguments: ["--root", repository.path]) != 0)
    }

    @Test("Release targets run the input guard")
    func releaseTargetsRunInputGuard() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let makefile = try String(
            contentsOf: repository.appendingPathComponent("Makefile"),
            encoding: .utf8
        )
        #expect(makefile.contains("release-check: release-input-check"))
        #expect(makefile.contains("notarized-dmg: release-input-check"))
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

    private func releaseInputScript() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/verify_release_inputs.sh")
    }

    private func makeReleaseFixture() throws -> URL {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = repository.appendingPathComponent("SapoWhisper")
        let project = repository.appendingPathComponent("SapoWhisper.xcodeproj")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("let tracked = true\n".utf8).write(
            to: source.appendingPathComponent("Tracked.swift")
        )
        let settings = """
            MARKETING_VERSION = 2.17.0;
            CURRENT_PROJECT_VERSION = 27;
            MARKETING_VERSION = 2.17.0;
            CURRENT_PROJECT_VERSION = 27;
            """
        try Data(settings.utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        try requireSuccess("/usr/bin/git", ["init", "-q"], in: repository)
        try requireSuccess(
            "/usr/bin/git",
            ["add", "SapoWhisper/Tracked.swift", "SapoWhisper.xcodeproj/project.pbxproj"],
            in: repository
        )
        return repository
    }

    private func requireSuccess(_ executable: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func run(_ executable: URL, arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func run(_ executable: URL, argument: URL) throws -> Int32 {
        try run(executable, arguments: [argument.path])
    }

    private func lineIndex(_ command: String, in lines: [String]) throws -> Int {
        try #require(lines.firstIndex(of: command))
    }
}
