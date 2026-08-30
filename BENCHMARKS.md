# SapoWhisper Benchmarks

This file is the public, aggregate scorecard for engine and AI-model decisions. It contains no user transcripts, recordings, vocabulary, local paths, account data, or private corpus fingerprints.

## Status (TL;DR)

Snapshot: 2026-08-29. Every claim below is bounded by the methodology sections that follow; read them before treating any line as a general benchmark.

## Publication status

The repository contains benchmark scripts and public fixture definitions, but no redacted run manifest. It does not publish the runner hash, the exact fixture IDs and hashes used for each row, per-run records, aggregate reference-word and error totals, or provider usage-token totals. Numeric screens that lack those fields are historical context only, not reproducible promotion evidence; a new comparison must publish the manifest before restoring numeric rankings or cost claims.

| Question | Answer | Why |
|---|---|---|
| Best overall accuracy STT | Not published | The historical Nova-3 comparison lacks a manifest and aggregate error/word totals; the current replacement Spanish fixture has no published score yet. |
| Best real-time STT | Deepgram Flux Live | Chosen for responsiveness; untested for WER, and falls back to the retained WAV via Nova-3 when post-close finalization is unproven or the final result is empty. |
| Best offline on Mac | MLX Large V3 Turbo | Quality default for offline Apple Silicon; no cloud round trip. The 4-bit tier is a lower-resource alternative, not a measured quality claim. |
| Best for technical Spanish | Not published | The historical comparison used retired `technical/es/real-natural.wav` and lacks a manifest; no score from the replacement fixture is published yet. |
| Best AI-polish quality and translation | Not published | Historical short and private acceptance screens lack a reproducible manifest; no model is promoted from their missing counters. |
| Best quality per price for Compact | Not published | The private Compact screen lacks provider usage-token totals and a reproducible manifest; 14-minute and 40-minute source-audio gates are still pending. |
| Best value, same language only | Not published | Historical translation and same-language results lack a reproducible manifest and verified per-call cost. |
| Cheapest offered polish | Not published | Provider rates drift, and no usage-token denominator is published for a per-call estimate. |
| Local LLM for polish | Not promoted | The historical local screen lacks a reproducible manifest; local models remain a speech-to-text option only. |

No per-call or campaign USD cost is published in this scorecard: the available records do not include provider usage-token totals and a declared sample denominator. Provider list prices are time-varying and are not a billing prediction.

## Promotion Rules

1. Freeze the prompt, corpus and fixture IDs/hashes, model ID, reasoning setting, and runner hash.
2. Run Normal, Compact, Normal + translation, and Compact + translation four times each.
3. Require zero uncompensated critical failures: semantic loss, inverted or missing negation, digit/name/path drift, wrong language, invalid output, runtime failure, instability, added answers, or collapse.
4. A short screen may reject a model but cannot fully promote it. Universal recommendations must also pass the long-input gates.
5. Compare latency and price only after fidelity passes.

## AI Polish Short Screen

Snapshot: 2026-08-29. A historical **preliminary screen, not a general benchmark**, used **one fully synthetic Spanish case** across four routes. Reasoning was requested **Off**. Four endpoints rejected that setting and their fallback requests used provider-default reasoning; their scope is called out below. The run's fixture ID/hash, runner hash, per-route records, and aggregate token totals are not published, so its numeric results are not reproducible from this tree.

- A future result may publish record counts only with the exact fixture, runner hash, per-run rows, and aggregate denominators. The former screen's counters are not published here.
- **p50** is valid only when repeated runs are present; it is the median wall-clock seconds from request start to full response for one dictation-sized polish call, not a throughput figure. No single-run latency is labeled p50.
- **Routes**, mapped to the Settings option:
  - **Normal** — polish with the standard style, output stays in the spoken language.
  - **Compact** — polish plus aggressive shortening, which is where content loss shows up first.
  - **Translation** — Normal or Compact with the target-language option enabled, so the model must both rewrite and change language.

Compact failure handling is path-dependent: its single whole-transcript call can keep the source text when polishing fails, while Normal's chunked path may salvage unaffected chunks. No provider or model tier is promised a universal fallback.

No per-model numeric result table is published for this screen. Its former 16/16 counters, p50/latency values, and USD-per-call estimates are withheld because the current tree lacks the manifest, per-run rows, aggregate denominators, and provider usage-token totals needed to recompute them.

### Historical candidate labels (not reproducible promotion)

- **Claude Opus 5:** prior fidelity/translation candidate; no reproducible public counter is published.
- **GPT-5.6 Sol:** prior Compact candidate from a private acceptance run; translation and long-input gates remain pending, with no public cost claim.
- **Qwen 3.8 Flash:** prior same-language candidate; translation was not qualified.
- **GPT-5.4 Nano:** prior fast candidate; any source-preserving fallback is path- and provider-dependent.
- **Qwen 3.5 Flash:** prior experimental candidate; not qualified for important instructions or translation.
- **Local AI polish:** experimental; no local refiner is promoted from the unmanifested screen.

These are historical labels under stated limits, not current promotion decisions. A tier can return only after a manifest-backed rerun.

SapoWhisper keeps the model field free-form because provider catalogs change. A model absent from this scorecard is unranked, not implicitly safe.

### Local AI polish models

A historical local-model screen ran on an NVIDIA RTX 3060 12 GB server, but its runner/fixture manifest and aggregate totals are not published. No local model is promoted for AI polish; local models remain speech-to-text candidates only.

## Compact route on real dictations (2026-08-29)

### Methodology

Two private Spanish acceptance dictations were checked locally through OpenRouter on the **Compact** route with reasoning **off** and temperature **0.1**. The dictation texts, fixture identifiers, runner hash, per-run records, and provider usage-token totals are **not published**. This was an acceptance check for the Compact route, **not** a statistical benchmark, and it says nothing about translation.

The app's Compact request budget is **60 s**. No per-model output ratio, latency, or USD table is published for this private run: its source texts and provider usage-token totals are unavailable to the public repo, so those measurements cannot be recalculated.

### Known limitation: reasoning "off" is not always honored

With reasoning **Off requested**, `x-ai/grok-4.6`, `qwen/qwen3.8-max`, `z-ai/glm-5.3-flash`, and `google/gemini-3.7-flash` returned **HTTP 400 "Reasoning is mandatory for this endpoint"**. SapoWhisper's fallback then resends the request without the reasoning field, so those models effectively ran with their **default reasoning**; no public latency or token result is retained for that run. The app cannot force reasoning off on endpoints that reject the parameter.

## Speech-to-Text Public Fixtures

### Methodology

The historical scorecard input was a dated public corpus snapshot and used **corrected WER**: each candidate first receives the declared deterministic recognition-replacement catalog, then the scorer normalizes casing, punctuation, and formatting before computing word error rate. The scorer emits `word_errors` and `reference_word_count` for each run, divides edit distance by the normalized reference-word count, and rounds WER to **two decimal places**. For an aggregate, a future manifest must publish the errors and reference words and state whether it uses `100 × Σword_errors / Σreference_word_count` or an explicitly chosen per-run aggregation; neither aggregate total is published here. Rows below were **not all captured under the same conditions**, so they are not directly comparable without reading the context column. Deepgram Nova-3 ran with the app's production keyterm and replacement context; the faster-whisper rows ran on a local NVIDIA server without a declared equivalent recognition prompt. Headline scores involving Spanish use the retired `technical/es/real-natural.wav` snapshot; the active synthetic replacement is tracked but not scored in this matrix.

Context is not a rounding detail: changing the app's keyterm/replacement context can materially change WER, so rows without equivalent context are not directly comparable.

The former numeric table is a historical aggregate, not a reproducible promotion manifest: candidate response files, runner hash, reference/error word totals, and per-run records are not published. Its values cannot be recalculated from the current tree alone and must not promote a future model; a new comparison must publish a redacted manifest under the Promotion Rules first.

| Engine | Context | Overall WER | English WER | Spanish WER | Speed |
|---|---|---:|---:|---:|---|
| Deepgram Nova-3 (batch) | Production keyterm/replacement context | not published | not published | not published | cloud batch |
| faster-whisper Large V3 Turbo (FP16, NVIDIA RTX 3060 12 GB server) | No declared equivalent context | not published | not published | not published | local NVIDIA batch |
| Deepgram Flux Live (realtime) | Production keyterm/replacement context | untested | untested | untested | chosen for responsiveness |
| ElevenLabs Scribe v2 (batch) | — | untested | untested | untested | — |
| ElevenLabs Scribe Realtime v2 | — | untested | untested | untested | — |

No STT WER winner is published from this historical snapshot because its aggregate errors, reference-word totals, fixture manifest, and runner hash are absent. Deepgram Flux Live is **untested for WER; chosen for responsiveness; falls back to Nova-3 when finalization is unproven or the final result is empty**. Its live path drains the sender before `CloseStream`, requires either a subsequent `Update` or a latest pre-close `Update` whose audio window is within 220 ms of the drained PCM, and then waits for the provider to close the stream. It accepts the documented no-status close (observed by Foundation as `1005`/`ENOTCONN`) only after that ordered sequence and otherwise re-transcribes the retained WAV. ElevenLabs Scribe v2 and Scribe Realtime v2 are untested here and are offered as unranked options.

### Public English fixture repeats

The promotion plan requires four repetitions over the public English fixtures. The historical comparison has no published per-run rows or aggregate errors/reference words, so no English WER is retained here.

The retired natural-voice Spanish fixture was exactly `technical/es/real-natural.wav` with reference `technical/es/real-natural.txt`; it is excluded from the current corpus and no speaker provenance is inferred here. It remains reachable in earlier public commits/releases because deleting it from the current tree is not a history purge. The active replacement is exactly `technical/es/synthetic-public.wav` with reference `technical/es/synthetic-public.txt`; the repository documents it as macOS Paulina system-voice audio generated from tracked public text, with no human voice or private recording in the current tree. No Spanish score from the replacement is published until a manifest-backed comparison completes. Turbo remains the local offline/LAN baseline.

### Cost

No Deepgram campaign USD total is published: the repository has no billed-minute/usage-token artifact and no declared per-dictation denominator for that campaign. Local faster-whisper and MLX runs have no provider per-minute charge beyond the hardware already owned.

## Local Transcription Tiers

- **MLX Large V3 Turbo:** quality default for offline Apple Silicon transcription.
- **MLX Large V3 Turbo 4-bit:** lower disk and memory use; transcription quality is not measured in this scorecard.
- **faster-whisper Large V3 Turbo:** recommended OpenAI-compatible NVIDIA STT server baseline.

AI polish and speech-to-text are different jobs. A recommended local transcription model is not automatically suitable for rewriting or translation.

## Updating This Scorecard

- Re-query provider availability and pricing.
- Keep the old dated row until a replacement completes the same frozen gates.
- Validate the instrument with coordinated-negation and case-sensitive technical-token controls.
- Read at least one actual output from every route before accepting counters.
- Publish a redacted manifest with runner hash, exact fixture IDs and SHA-256 hashes, route/repetition rows, reference-word and error totals, provider usage tokens, and the cost denominator before restoring numeric scores.
- Treat History replay as an aggregate/redaction utility, not a live-engine parity benchmark: its transcription request does not reproduce the app's complete recognition prompt, language, or VAD settings.
- Publish aggregate results only; private audio/text and provider responses stay outside the repository.
