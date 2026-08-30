//
//  VocabularyManagerTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

@MainActor
final class VocabularyManagerTests: XCTestCase {

    /// A manager backed by a throwaway temp file, so tests never read or write
    /// the user's real vocabulary.json.
    private func makeManager() -> VocabularyManager {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-test-\(UUID().uuidString).json")
        return VocabularyManager(fileURL: url)
    }

    // MARK: - STT initial prompt

    /// The local-STT glossary must show only canonical spellings: keyterms
    /// plus replacement values, never misheard keys or confusion variants
    /// (feeding "Sapo Visper" to the decoder would teach it the wrong form).
    func testInitialPromptTextUsesCanonicalFormsOnly() {
        let manager = makeManager()
        manager.addKeyterm("SapoWhisper")
        manager.addKeyterm("CHANGELOG")
        manager.addReplacement(from: "buen mouse", to: "BuenMouse")

        let prompt = manager.initialPromptText()

        XCTAssertEqual(prompt, "Glossary: SapoWhisper, CHANGELOG, BuenMouse.")
        XCTAssertFalse(prompt.contains("buen mouse"))
        XCTAssertFalse(prompt.contains("Sapo Whisper"))
    }

    func testInitialPromptTextHonorsLengthCapKeepingKeytermsFirst() {
        let manager = makeManager()
        for index in 0..<80 {
            manager.addKeyterm("VeryLongTechnicalTerm\(index)WithPadding")
        }

        let prompt = manager.initialPromptText(maxLength: 200)

        XCTAssertLessThanOrEqual(prompt.count, 200)
        XCTAssertTrue(prompt.hasPrefix("Glossary: VeryLongTechnicalTerm0WithPadding"))
        XCTAssertTrue(prompt.hasSuffix("."))
        XCTAssertFalse(prompt.contains("VeryLongTechnicalTerm79WithPadding"))
    }

    func testInitialPromptTextBenchmarkParityFixture() {
        let manager = makeManager()
        manager.addKeyterm("AlphaTool")
        manager.addKeyterm("alphatool")
        manager.addKeyterm("BetaCLI")
        manager.addReplacement(from: "heard beta", to: "BetaCLI")
        manager.addReplacement(from: "heard gamma", to: "GammaAPI")

        XCTAssertEqual(manager.initialPromptText(), "Glossary: AlphaTool, BetaCLI, GammaAPI.")
        XCTAssertEqual(manager.initialPromptText(maxLength: 24), "Glossary: AlphaTool.")

        manager.setIncludeReplacementTargetsInRecognitionHints(false)

        XCTAssertEqual(manager.initialPromptText(), "Glossary: AlphaTool, BetaCLI.")
    }

    func testInitialPromptTextEmptyWithoutVocabulary() {
        XCTAssertEqual(makeManager().initialPromptText(), "")
    }

    func testReplacementTargetsAreRecognitionHintsByDefaultAndPersist() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-test-\(UUID().uuidString).json")
        let manager = VocabularyManager(fileURL: url)
        manager.addReplacement(from: "cloud code", to: "Claude Code")

        XCTAssertTrue(manager.includeReplacementTargetsInRecognitionHints)
        XCTAssertEqual(manager.initialPromptText(), "Glossary: Claude Code.")

        manager.setIncludeReplacementTargetsInRecognitionHints(false)

        XCTAssertFalse(VocabularyManager(fileURL: url).includeReplacementTargetsInRecognitionHints)
    }

    func testRecognitionHintsCanExcludeReplacementTargetsWithoutDisablingCorrections() {
        let manager = makeManager()
        manager.addKeyterm("SapoWhisper")
        manager.addReplacement(from: "cloud code", to: "Claude Code")
        manager.setIncludeReplacementTargetsInRecognitionHints(false)

        XCTAssertEqual(manager.initialPromptText(), "Glossary: SapoWhisper.")
        XCTAssertEqual(manager.echoDetectionTerms(), ["SapoWhisper"])
        XCTAssertEqual(manager.keytermQueryItems().compactMap(\.value), ["SapoWhisper"])
        XCTAssertEqual(
            manager.recognitionKeytermPayload(maxCount: 10, maxLength: 50).terms,
            ["SapoWhisper"]
        )
        XCTAssertEqual(manager.replaceQueryItems().compactMap(\.value), ["cloud code:Claude Code"])
        XCTAssertEqual(
            manager.applyingRecognitionCorrections(to: "abre cloud code"),
            "abre Claude Code"
        )
    }

    func testElevenLabsBuildersRespectReplacementHintPreference() {
        let manager = makeManager()
        manager.addKeyterm("SapoWhisper")
        manager.addReplacement(from: "cloud code", to: "Claude Code")
        manager.setIncludeReplacementTargetsInRecognitionHints(false)

        XCTAssertEqual(
            ElevenLabsScribeTranscriber.recognitionKeytermPayload(from: manager).terms,
            ["SapoWhisper"]
        )
        XCTAssertEqual(
            ElevenLabsScribeRealtimeTranscriber.recognitionKeytermPayload(from: manager).terms,
            ["SapoWhisper"]
        )
    }

    func testVocabularySnapshotRoundTripPreservesRecognitionHintPreference() throws {
        let source = makeManager()
        source.setIncludeReplacementTargetsInRecognitionHints(false)
        let data = try JSONEncoder().encode(source.snapshot())
        let snapshot = try JSONDecoder().decode(VocabularySnapshot.self, from: data)

        let destination = makeManager()
        destination.merge(snapshot: snapshot)

        XCTAssertFalse(destination.includeReplacementTargetsInRecognitionHints)
    }

    func testLegacyVocabularySnapshotDoesNotOverrideRecognitionHintPreference() throws {
        let data = #"{"keyterms":[],"replacements":{}}"#.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(VocabularySnapshot.self, from: data)
        let manager = makeManager()
        manager.setIncludeReplacementTargetsInRecognitionHints(false)

        manager.merge(snapshot: snapshot)

        XCTAssertFalse(manager.includeReplacementTargetsInRecognitionHints)
    }

    // MARK: - Replacements

    func testApplyingReplacementsIsWholeWordCaseInsensitive() {
        let manager = makeManager()
        manager.addReplacement(from: "kubernetes", to: "Kubernetes")
        XCTAssertEqual(manager.applyingReplacements(to: "uso kubernetes a diario"), "uso Kubernetes a diario")
        // Whole-word only: a longer token must be left untouched.
        XCTAssertEqual(manager.applyingReplacements(to: "kubernetesx"), "kubernetesx")
    }

    func testApplyingReplacementsHandlesSpokenPunctuation() {
        let manager = makeManager()
        manager.addReplacement(from: "deep.gram", to: "Deepgram")
        // "deep gram" (the dot spoken as a space) still maps to the canonical form.
        XCTAssertEqual(manager.applyingReplacements(to: "abrí deep gram hoy"), "abrí Deepgram hoy")
    }

    func testLongerReplacementKeysWinFirst() {
        let manager = makeManager()
        manager.addReplacement(from: "git", to: "Git")
        manager.addReplacement(from: "git hub", to: "GitHub")
        // The longer key is applied first, so "git hub" becomes "GitHub" whole.
        XCTAssertEqual(manager.applyingReplacements(to: "abrí git hub ayer"), "abrí GitHub ayer")
    }

    /// An expansion pair whose key survives inside its own value ("push" ->
    /// "git push") re-triggers on already-correct text: mechanically it turns
    /// "git push" into "git git push". Those pairs must be skipped by the
    /// local pass and by Deepgram's server-side replace, and stay available
    /// only to the AI polish dictionary, which reads context.
    func testSelfRetriggeringPairsAreSkippedByMechanicalPasses() {
        let manager = makeManager()
        manager.addReplacement(from: "push", to: "git push")
        manager.addReplacement(from: "code", to: "Claude Code")
        manager.addReplacement(from: "get push", to: "git push")

        XCTAssertEqual(
            manager.applyingReplacements(to: "haces git push y luego el code review"),
            "haces git push y luego el code review"
        )
        // A true mishearing key still applies.
        XCTAssertEqual(manager.applyingReplacements(to: "haces get push ahora"), "haces git push ahora")
        XCTAssertEqual(
            manager.replaceQueryItems().compactMap(\.value),
            ["get push:git push"]
        )

        let outputWithHints = manager.applyingRecognitionCorrections(to: "haz push")
        manager.setIncludeReplacementTargetsInRecognitionHints(false)
        XCTAssertEqual(manager.applyingRecognitionCorrections(to: "haz push"), outputWithHints)
    }

    /// Case-normalization ("kubernetes" -> "Kubernetes") and spoken-dot pairs
    /// ("deep.gram" -> "Deepgram") re-apply as no-ops, so they stay mechanical.
    func testIdempotentPairsRemainMechanical() {
        let manager = makeManager()
        manager.addReplacement(from: "kubernetes", to: "Kubernetes")
        manager.addReplacement(from: "deep.gram", to: "Deepgram")

        XCTAssertEqual(
            manager.applyingReplacements(to: "uso kubernetes y deep gram"),
            "uso Kubernetes y Deepgram"
        )
        XCTAssertEqual(manager.replaceQueryItems().count, 2)
    }

    // MARK: - Recognition keyterm payload

    func testKeytermPayloadKeepsSavedTermsFirst() {
        let manager = makeManager()
        manager.addKeyterm("GitHub")
        let payload = manager.recognitionKeytermPayload(maxCount: 10, maxLength: 50, maxWords: nil)
        XCTAssertEqual(payload.terms.first, "GitHub")
    }

    func testKeytermPayloadDropsOverLongTerms() {
        let manager = makeManager()
        let longTerm = String(repeating: "a", count: 60)
        manager.addKeyterm(longTerm)
        let payload = manager.recognitionKeytermPayload(maxCount: 100, maxLength: 50, maxWords: nil)
        XCTAssertFalse(payload.terms.contains(longTerm))
    }

    func testKeytermPayloadHonorsMaxCount() {
        let manager = makeManager()
        manager.addKeyterm("alpha")
        manager.addKeyterm("beta")
        manager.addKeyterm("gamma")
        let payload = manager.recognitionKeytermPayload(maxCount: 2, maxLength: 50, maxWords: nil)
        XCTAssertEqual(payload.terms.count, 2)
        XCTAssertGreaterThan(payload.droppedCount, 0)
    }

    // MARK: - Limits and query items

    func testElevenLabsLimitViolationsCountsOverLongTerms() {
        let manager = makeManager()
        manager.addKeyterm(String(repeating: "a", count: 60))  // over batch (50) and realtime (20)
        manager.addKeyterm(String(repeating: "b", count: 25))  // over realtime (20) only
        let violations = manager.elevenLabsLimitViolations()
        XCTAssertEqual(violations.batch, 1)
        XCTAssertEqual(violations.realtime, 2)
    }

    func testDeepgramKeytermQueryParamIsSingular() {
        let manager = makeManager()
        manager.addKeyterm("Kubernetes")
        // AGENTS.md: Deepgram Nova-3 uses the singular `keyterm` query param.
        XCTAssertEqual(manager.keytermQueryItems().first?.name, "keyterm")
    }

    /// Cloud hints carry CANONICAL spellings only: sending misheard variants
    /// ("punto geek ignore", "Kit commit") as keyterms biases the engine
    /// toward the wrong form and burns the provider's term budget. Variants
    /// are recovered locally by the correction pass instead.
    func testDeepgramKeytermQuerySendsOnlyCanonicalForms() {
        let manager = makeManager()
        manager.addKeyterm(".gitignore")
        manager.addKeyterm("git commit")
        manager.addReplacement(from: "cloud code", to: "Claude Code")

        let values = manager.keytermQueryItems().compactMap(\.value)

        XCTAssertEqual(values, [".gitignore", "git commit", "Claude Code"])
    }

    func testDeepgramKeytermQueryHonorsTotalWordBudget() {
        let manager = makeManager()
        for index in 0..<600 {
            manager.addKeyterm("term\(index)")
        }

        let totalWords = manager.keytermQueryItems()
            .compactMap(\.value)
            .map { max(1, $0.split(separator: " ").count) }
            .reduce(0, +)

        XCTAssertLessThanOrEqual(totalWords, DeepgramKeytermLimits.maxTotalWords)
    }

    // MARK: - Recognition corrections

    func testRecognitionCorrectionsPreserveSavedCanonicalForms() {
        let manager = makeManager()
        manager.addKeyterm("GitHub")
        manager.addKeyterm("git push")
        manager.addKeyterm("APP STORE CONNECT")

        let output = manager.applyingRecognitionCorrections(
            to: "open github before Git Push and app store connect"
        )

        XCTAssertEqual(output, "open GitHub before git push and APP STORE CONNECT")
    }

    func testRecognitionCorrectionsHandleSpokenTechnicalForms() {
        let manager = makeManager()
        manager.addKeyterm("SapoWhisper")
        manager.addKeyterm("CLAUDE.md")
        manager.addKeyterm("AGENTS.md")
        manager.addKeyterm("Claude Code")
        manager.addKeyterm("Deepgram")
        manager.addKeyterm("ElevenLabs batch")
        manager.addKeyterm("Jellyfin")
        manager.addKeyterm("Hetzner")
        manager.addKeyterm("git push")

        let output = manager.applyingRecognitionCorrections(
            to:
                "Open SAP-O-Whisper, update CloudMD, then read AgentsMD with ClaucoCode, Ditgram, 11labsbatch, Jellifin, Etzner, and hitpug."
        )

        XCTAssertEqual(
            output,
            "Open SapoWhisper, update CLAUDE.md, then read AGENTS.md with Claude Code, Deepgram, ElevenLabs batch, Jellyfin, Hetzner, and git push."
        )
    }

    func testRecognitionCorrectionsHandlePersonalIABrainAndChangelogForms() {
        let manager = makeManager()
        manager.addKeyterm("IABrain")
        manager.addKeyterm("CHANGELOG")
        manager.addKeyterm("AGENTS.md")

        XCTAssertEqual(
            manager.applyingRecognitionCorrections(
                to: "revisa ya brain, changelov y AGENTS punto eme de"
            ),
            "revisa IABrain, CHANGELOG y AGENTS.md"
        )
        XCTAssertEqual(
            manager.recognitionKeytermPayload(maxCount: 20, maxLength: 200).terms,
            ["IABrain", "CHANGELOG", "AGENTS.md"]
        )
    }

    func testRecognitionCorrectionsHandlePersonalGitPhrasesWithoutSeparateGitTerm() {
        let manager = makeManager()
        manager.addKeyterm("git commit")
        manager.addKeyterm("git push")

        XCTAssertEqual(
            manager.applyingRecognitionCorrections(
                to: "ejecuta HIIT con meat y HIIT push; luego heat con meat y heat push"
            ),
            "ejecuta git commit y git push; luego git commit y git push"
        )
    }

    func testRecognitionCorrectionsHandlePunctuationAndNarratorVariants() {
        let manager = makeManager()
        manager.addKeyterm("SapoWhisper")
        manager.addKeyterm("CLAUDE.md")
        manager.addKeyterm("App Store Connect")
        manager.addKeyterm("Claude Code")
        manager.addKeyterm("pull request")
        manager.addKeyterm("Hetzner")
        manager.addKeyterm("Cloudflare")
        manager.addKeyterm("AGENTS.md")
        manager.addKeyterm("Nova-3")
        manager.addKeyterm("Scribe v2")

        let output = manager.applyingRecognitionCorrections(
            to:
                "Open SAP Awhisper, then claud.mendy with Store Connect, claudcode, pull, request, Etsner, NATS.md, Nova three, Scribe v two, and ClavFlare."
        )

        XCTAssertEqual(
            output,
            "Open SapoWhisper, then CLAUDE.md with App Store Connect, Claude Code, pull request, Hetzner, AGENTS.md, Nova-3, Scribe v2, and Cloudflare."
        )
    }

    func testRecognitionCorrectionsHandleDotPrefixedTermsWithoutDuplicatingDots() {
        let manager = makeManager()
        manager.addKeyterm(".env")
        manager.addKeyterm(".md")
        manager.addKeyterm("AGENTS.md")

        let output = manager.applyingRecognitionCorrections(
            to: "menciona punto m, punto md y Ages punto m d"
        )

        XCTAssertEqual(output, "menciona .env, .md y AGENTS.md")
        XCTAssertEqual(manager.applyingRecognitionCorrections(to: output), output)
    }

    func testRecognitionCorrectionsHandleAgentsLegendsConfusion() {
        let manager = makeManager()
        manager.addKeyterm("AGENTS.md")

        XCTAssertEqual(
            manager.applyingRecognitionCorrections(to: "actualizaste legends.md y Claude Code.md"),
            "actualizaste AGENTS.md y Claude Code.md"
        )

        let managerWithBothTerms = makeManager()
        managerWithBothTerms.addKeyterm("AGENTS.md")
        managerWithBothTerms.addKeyterm("legends.md")
        XCTAssertEqual(
            managerWithBothTerms.applyingRecognitionCorrections(to: "actualizaste legends.md"),
            "actualizaste legends.md"
        )
    }

    func testRecognitionCorrectionsHandleRealSpanishTechnicalVariants() {
        let manager = makeManager()
        manager.addKeyterm("git")
        manager.addKeyterm("commit")
        manager.addKeyterm("git commit")
        manager.addKeyterm("git push")
        manager.addKeyterm("Hetzner")
        manager.addKeyterm("Jellyfin")
        manager.addKeyterm("Kimi V2")
        manager.addKeyterm("qBittorrent")
        manager.addKeyterm("Vue 3")

        let output = manager.applyingRecognitionCorrections(
            to: "HacerunComet con Edsner, JellyFy, KimiVersión2, Cubitorrel y Vue three."
        )

        XCTAssertEqual(
            output,
            "commit con Hetzner, Jellyfin, Kimi V2, qBittorrent y Vue 3."
        )
        XCTAssertEqual(manager.applyingRecognitionCorrections(to: "uso Kimi p 2"), "uso Kimi V2")
        XCTAssertEqual(manager.applyingRecognitionCorrections(to: "hago Kimi"), "git commit")
        XCTAssertEqual(manager.applyingRecognitionCorrections(to: "haz un deep comment y un deep push"), "haz un git commit y un git push")
        XCTAssertEqual(manager.applyingRecognitionCorrections(to: "abre Vue"), "abre Vue")
    }

    func testRecognitionCorrectionsHandleGitPhrasesFromSeparateTerms() {
        let manager = makeManager()
        manager.addKeyterm("git")
        manager.addKeyterm("commit")
        manager.addKeyterm("push")

        let output = manager.applyingRecognitionCorrections(
            to: "haz un deep comment y un deep push"
        )

        XCTAssertEqual(output, "haz un git commit y un git push")

        let managerWithoutGit = makeManager()
        managerWithoutGit.addKeyterm("commit")
        managerWithoutGit.addKeyterm("push")
        XCTAssertEqual(
            managerWithoutGit.applyingRecognitionCorrections(to: "haz un deep comment y un deep push"),
            "haz un deep comment y un deep push"
        )
    }

    func testRecognitionCorrectionsHandleKitGitCommandConfusionsWhenGitIsKnown() {
        let manager = makeManager()
        manager.addKeyterm("git")

        XCTAssertEqual(
            manager.applyingRecognitionCorrections(to: "hacer KitCom y KitPush"),
            "hacer git commit y git push"
        )

        let managerWithoutGit = makeManager()
        XCTAssertEqual(
            managerWithoutGit.applyingRecognitionCorrections(to: "hacer KitCom y KitPush"),
            "hacer KitCom y KitPush"
        )
    }

    func testRecognitionCorrectionsHandleNaturalSpanishFixtureVariants() {
        let manager = makeManager()
        manager.addKeyterm(".env")
        manager.addKeyterm(".gitignore")
        manager.addKeyterm("Local AI Server")
        manager.addKeyterm("Local AI Server (NVIDIA)")
        manager.addKeyterm("AI polish")
        manager.addKeyterm("Nova-3")
        manager.addKeyterm("Scribe v2")
        manager.addKeyterm("TestFlight")
        manager.addKeyterm("PostgreSQL")
        manager.addKeyterm("Cloudflare")
        manager.addKeyterm("WireGuard")
        manager.addKeyterm("SQLite")
        manager.addKeyterm("UserDefaults")
        manager.addKeyterm("REST API")
        manager.addKeyterm("pull request")

        let output = manager.applyingRecognitionCorrections(
            to:
                "punto emb, punto geek ignore, local ya server, local ya server NVIDIA, a AI, Nova tres, Scribe versión dos, TestFly, Postgres SQL, CloudFair, WifeWare, UseSqlite, User Default, RESTAPI y pool request"
        )

        XCTAssertEqual(
            output,
            ".env, .gitignore, Local AI Server, Local AI Server (NVIDIA), AI polish, Nova-3, Scribe v2, TestFlight, PostgreSQL, Cloudflare, WireGuard, SQLite, UserDefaults, REST API y pull request"
        )
    }

    /// Single-word variants that are real everyday words must never apply
    /// mechanically: "a hit on Spotify" is not about git, and the old pass
    /// rewrote exactly that (plus "pug"→push, "comet"→commit, "cloud"→Claude).
    /// Multi-word variants ("hit pug") stay mechanical — the bigram is
    /// specific enough.
    func testRecognitionCorrectionsLeaveRealWordVariantsAlone() {
        let manager = makeManager()
        manager.addKeyterm("git")
        manager.addKeyterm("git push")
        manager.addKeyterm("commit")
        manager.addKeyterm("Claude")

        let input = "a hit on Spotify, mi perro pug, el comet Halley y cloud storage"
        XCTAssertEqual(manager.applyingRecognitionCorrections(to: input), input)

        // The bigram form still corrects.
        XCTAssertEqual(manager.applyingRecognitionCorrections(to: "haz hit pug ahora"), "haz git push ahora")
    }

    /// A correction match must not swallow a sentence-ending period: the old
    /// short-token pattern carried a trailing `\.?` and turned "un comit.
    /// Luego…" into "un commit Luego…".
    func testRecognitionCorrectionsPreserveSentencePeriod() {
        let manager = makeManager()
        manager.addKeyterm("commit")

        XCTAssertEqual(
            manager.applyingRecognitionCorrections(to: "haz un comit. Luego revisa el estado."),
            "haz un commit. Luego revisa el estado."
        )
    }

    func testRecognitionCorrectionsDoNotReplaceInsideLongerWords() {
        let manager = makeManager()
        manager.addKeyterm("Codex")

        XCTAssertEqual(
            manager.applyingRecognitionCorrections(to: "codexical examples are different from codex"),
            "codexical examples are different from Codex"
        )
    }

    func testRecognitionCorrectionsAvoidAmbiguousNearTerms() {
        let manager = makeManager()
        manager.addKeyterm("Codex")
        manager.addKeyterm("Claude Code")
        manager.addKeyterm("UUID")

        XCTAssertEqual(
            manager.applyingRecognitionCorrections(to: "Code, Cloudflare y UID no son equivalentes."),
            "Code, Cloudflare y UID no son equivalentes."
        )
    }
}
