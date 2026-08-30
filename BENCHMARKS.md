# SapoWhisper Benchmarks

This file is the public, aggregate scorecard for engine and AI-model decisions. It contains no user transcripts, recordings, vocabulary, local paths, account data, or private corpus fingerprints.

## Recommendations (TL;DR)

Snapshot: 2026-08-29. Every claim below is bounded by the methodology sections that follow; read them before treating any line as a general benchmark.

| Question | Answer | Why |
|---|---|---|
| Best overall accuracy STT | Deepgram Nova-3 (batch, with the app's keyterm context) | 2.776% corrected WER overall on the public authored corpus, 1.149% English. |
| Best real-time STT | Deepgram Flux Live | Chosen for responsiveness; untested for WER, falls back to the retained WAV via Nova-3 on abnormal socket close. |
| Best offline on Mac | MLX Large V3 Turbo (4-bit for lower disk/memory) | Quality default for offline Apple Silicon; no cloud round trip. |
| Best for technical Spanish | faster-whisper Large V3 Turbo on a local NVIDIA server | Narrowly wins authored Spanish (8.143% vs 8.306%) and keeps technical terms and digits; Nova-3 still wins English and overall. |
| Best AI-polish quality and translation | `anthropic/claude-opus-5` | Only model with zero critical failures across all four routes in the short screen, translation included, and clean on both real Compact dictations. |
| Best quality per price for Compact | `openai/gpt-5.6-sol` | Clean on both real Spanish dictations, densest output (27% of source), 7.9 s, ~$0.012 per long dictation — about a quarter of the Opus 5 cost. Long-input gates still pending. |
| Best value, same language only | `qwen/qwen3.8-flash` | Passes same-language cleanup at ~1/44 of Opus 5 cost; fails every translation record. |
| Cheapest offered polish | `qwen/qwen3.5-flash-02-23` | ~US$0.010 per 100 dictations; economy tier only, not for important instructions or translation. |
| Local LLM for polish | **Not recommended** | 7 small local models on an RTX 3060 12 GB, 0 passed the four-route gate. Use local models for STT, not for polish. |

Cost anchors as of 2026-08-29: Opus 5 polish costs roughly US$0.93 per 100 short dictations; the whole Nova-3 campaign cost about US$7.15 for ~687 billed minutes. Speech-to-text results and the Nova-3 recommendation are unchanged by the 2026-08-29 polish run.

## Promotion Rules

1. Freeze the prompt, synthetic/public corpus, model ID, reasoning setting, and runner hash.
2. Run Normal, Compact, Normal + translation, and Compact + translation four times each.
3. Require zero uncompensated critical failures: semantic loss, inverted or missing negation, digit/name/path drift, wrong language, invalid output, runtime failure, instability, added answers, or collapse.
4. A short screen may reject a model but cannot fully promote it. Universal recommendations must also pass the long-input gates.
5. Compare latency and price only after fidelity passes.

## AI Polish Short Screen

Snapshot: 2026-08-29. This is a **preliminary screen, not a general benchmark**: it is **one fully synthetic Spanish case**, run over **four routes**, **four repetitions each**, giving **16 records per model**. Reasoning was disabled. Prices are USD per million tokens from the [OpenRouter models API](https://openrouter.ai/api/v1/models) on that date and will drift.

- **16/16** means 16 of those 16 records had zero uncompensated critical failures under the Promotion Rules. It does not mean 16 distinct texts, and it says nothing about long inputs.
- **p50** is the median wall-clock seconds from request start to full response for one dictation-sized polish call on that single case; it is a latency indicator, not a throughput figure.
- **Routes**, mapped to the Settings option:
  - **Normal** — polish with the standard style, output stays in the spoken language.
  - **Compact** — polish plus aggressive shortening, which is where content loss shows up first.
  - **Translation** — Normal or Compact with the target-language option enabled, so the model must both rewrite and change language.

| Model | Input / output | p50 | Est. cost / 100 dictations | Verdict | Evidence |
|---|---:|---:|---:|---|---|
| anthropic/claude-opus-5 | $5.00 / $25.00 | 9.32 s | ~$0.93 | Offered as best tested | **16/16 critical pass**, including both translation routes. Best tested; long 14/40-minute gates pending. |
| z-ai/glm-5.3-flash | $0.075 / $0.25 | 23.57 s | ~$0.011 | Rejected, not offered | Failed the language gate and the runtime-failure gate. This model rejects `reasoning: none`, so its row ran with the provider's default reasoning. |
| qwen/qwen3.8-flash | $0.15 / $0.47 | 9.05 s | ~$0.021 | Rejected as universal default / offered as same-language value | Failed the translation gate on all 8 translation records and the stability gate (runtime instability). Passed same-language fidelity. |
| openai/gpt-5.6-sol | $2.00 / $10.00 | 11.75 s | ~$0.37 | Rejected as universal default / offered as best quality per price for Compact | Failed the semantic gate, the case-sensitive technical-token gate, the translation gate, and the runtime gate on this synthetic screen. Later cleared both real Compact dictations (see the 2026-08-29 section); the translation limitation stands. |
| openai/gpt-5.4-nano | $0.20 / $1.25 | 6.13 s | ~$0.043 | Rejected as universal default / offered as fast budget | Failed the content-preservation gate on hard Compact records and the language gate on hard translation records. Fastest tested. |
| deepseek/deepseek-v4-flash-0731 | $0.045 / $0.09 | 25.64 s | ~$0.005 | Rejected, not offered | Failed requirements, negations, digits, names, paths, translation, stability, and collapse gates. |
| openai/gpt-5.6-luna | $0.20 / $1.20 | 8.81 s | ~$0.042 | Rejected, not offered | Failed the semantic, translation, runtime, and stability gates. |
| qwen/qwen3.5-flash-02-23 | $0.065 / $0.26 | 8.47 s | ~$0.010 | Rejected as universal default / offered as economy | Failed the fidelity, translation, runtime, and stability gates. Offered only for low-stakes same-language cleanup where a bad rewrite costs nothing. |

Cost estimates assume ~600 input and ~250 output tokens per dictation, priced with the per-MTok values in the same row, as of 2026-08-29. They are a comparison aid, not a billing prediction. Anthropic lists Claude Opus 4.8 and Opus 5 at the same price (US$5.00 in / US$25.00 out per MTok, checked 2026-08-29), so choosing 4.8 offers no cost advantage over Opus 5.

### User-facing tiers

- **Best tested:** Claude Opus 5. Use when fidelity and translation matter more than cost.
- **Best quality per price:** GPT-5.6 Sol. Compact-route pick on real dictations; not qualified for translation.
- **Same-language value:** Qwen 3.8 Flash. Do not select it for translation.
- **Fast budget:** GPT-5.4 Nano. SapoWhisper's guards may keep the source text on hard cases.
- **Economy:** Qwen 3.5 Flash. Avoid for important instructions and translation.
- **Local AI polish:** experimental. No small local refiner currently qualifies as a recommendation.

A tier is an offer under stated limits, not a clean pass. Only Claude Opus 5 cleared every route.

SapoWhisper keeps the model field free-form because provider catalogs change. A model absent from this table is unranked, not implicitly safe.

### Local AI polish models

Seven small local models were screened on an NVIDIA RTX 3060 12 GB server: Qwen 3.5 4B, Qwen 3.5 2B, Qwen3.8-4B-Distill Q4_K_M, Granite 4 H Tiny, Ministral 3B, LFM2.5 1.2B, and Gemma. **Zero passed the four-route gate.** The typical failures were dropped requirements, inverted or missing negations, digit drift, and collapsed translations. Local models are recommended for speech-to-text only, not for AI polish.

## Compact route on real dictations (2026-08-29)

### Methodology

Two real Spanish dictations by the author, run through OpenRouter on the **Compact** route with reasoning **off** and temperature **0.1**: a long one of **3 m 47 s / 651 words** and a short one of **28 s**. The dictation texts are private and are **not published**; only aggregate figures appear here. Each output was judged manually on retention of instructions, negations, proper names, numbers, file paths, and commands. Two dictations are an acceptance check for the Compact route, **not** a statistical benchmark, and they say nothing about translation.

**Output/input ratio long** is polished output length over source length on the 651-word dictation: lower means denser compaction, and a collapse (very low ratio) is a failure, not a win. **Latency long** is wall-clock seconds for the long dictation; the app's Compact request budget is **60 s**.

| Model | Slug | $in / $out per MTok | Output/input ratio (long) | Latency (long) | Est. cost per long dictation | Verdict |
|---|---|---:|---:|---:|---:|---|
| Claude Opus 5 | `anthropic/claude-opus-5` | $5.00 / $25.00 | 40% | 15.4 s (p50) | ~$0.052 | Kept as best tested — clean on both dictations, and the only 16/16 on the short synthetic screen. |
| GPT-5.6 Sol | `openai/gpt-5.6-sol` | $2.00 / $10.00 | 27% | 7.9 s | ~$0.012 | Promoted to best quality per price — clean on both, densest output, ~1/4 of the Opus 5 cost at ~2x its speed. |
| Grok 4.6 | `x-ai/grok-4.6` | not re-queried | faithful | 58.8 s | not computed | Rejected on latency: 58.8 s against a 60 s Compact timeout leaves no margin. |
| GLM 5.3 Flash | `z-ai/glm-5.3-flash` | $0.075 / $0.25 | non-deterministic (one provider returned 9 words for the 651-word source) | 57.8 s | not computed | Rejected: output varies by upstream provider and latency sits at the timeout. |
| Qwen3.8 Max | `qwen/qwen3.8-max` | not re-queried | verbose (10.9k output tokens) | 250.9 s | not computed | Rejected: far past the timeout, dropped a number, reordered tasks, ignored the dictionary. |
| Gemini 3.7 Flash | `google/gemini-3.7-flash` | not re-queried | not computed | 6.8 s | not computed | Rejected on fidelity: dropped the same number and mistranslated a proper name despite being the fastest. |

Prices for rejected models were not re-queried on this date; the two promoted rows use the same per-MTok values as the short-screen table. Cost estimates are a comparison aid, not a billing prediction.

### Known limitation: reasoning "off" is not always honored

With the reasoning setting **off**, `x-ai/grok-4.6`, `qwen/qwen3.8-max`, `z-ai/glm-5.3-flash`, and `google/gemini-3.7-flash` returned **HTTP 400 "Reasoning is mandatory for this endpoint"**. SapoWhisper's fallback then resends the request without the reasoning field, so those models effectively ran with their **default reasoning**, which inflates both latency and output tokens. Their numbers above are therefore "default reasoning" numbers, and the app currently offers no way to force reasoning off on such endpoints.

## Speech-to-Text Public Fixtures

### Methodology

Scores come from a public authored corpus and are reported as **corrected WER**: word error rate after normalizing casing, punctuation, and formatting differences that do not change meaning. Rows below were **not all captured under the same conditions**, so they are not directly comparable without reading the context column. Deepgram Nova-3 ran with the app's production keyterm and replacement context; the faster-whisper rows ran on a local NVIDIA server without a declared equivalent context.

Context is not a rounding detail: removing the app's keyterm/replacement context regressed Spanish WER to roughly **16%**, so any Nova-3 number quoted without that context is not the number below.

| Engine | Context | Overall WER | English WER | Spanish WER | Speed |
|---|---|---:|---:|---:|---|
| Deepgram Nova-3 (batch) | Production keyterm/replacement context | **2.776%** | **1.149%** | 8.306% | cloud batch |
| faster-whisper Large V3 Turbo (FP16, NVIDIA RTX 3060 12 GB server) | No declared equivalent context | 4.811% | 3.831% | **8.143%** | RTF ≈0.035 (≈29x realtime) |
| Deepgram Flux Live (realtime) | Production keyterm/replacement context | untested | untested | untested | chosen for responsiveness |
| ElevenLabs Scribe v2 (batch) | — | untested | untested | untested | — |
| ElevenLabs Scribe Realtime v2 | — | untested | untested | untested | — |

Nova-3 leads overall and in English. Large V3 Turbo narrowly leads authored Spanish and stays local. Deepgram Flux Live is **untested for WER; chosen for responsiveness; falls back to Nova-3 on abnormal close** — its close path accepts only a normal provider socket termination and otherwise re-transcribes the retained WAV. ElevenLabs Scribe v2 and Scribe Realtime v2 are untested here and are offered as unranked options.

### Public English fixture repeats

Four repetitions over the unchanged public English fixtures:

| Engine | Corrected English WER |
|---|---:|
| Deepgram Nova-3 with production context | **1.149%** |
| faster-whisper Large V3 Turbo (FP16, NVIDIA) | 3.831% |

The previous Spanish natural-voice fixture was removed from the repository and replaced by a system-generated public fixture; no Spanish score from this specific four-repeat fixture matrix is published until the replacement completes it. Turbo remains the local offline/LAN baseline.

### Cost

The Deepgram Nova-3 campaign cost approximately **US$7.15 for ~687 billed minutes** (as of 2026-08-29). Local faster-whisper and MLX runs have no per-minute cost beyond the hardware already owned.

## Local Transcription Tiers

- **MLX Large V3 Turbo:** quality default for offline Apple Silicon transcription.
- **MLX Large V3 Turbo 4-bit:** lower disk and memory use with comparable transcription quality.
- **faster-whisper Large V3 Turbo:** recommended OpenAI-compatible NVIDIA STT server baseline.

AI polish and speech-to-text are different jobs. A recommended local transcription model is not automatically suitable for rewriting or translation.

## Updating This Scorecard

- Re-query provider availability and pricing.
- Keep the old dated row until a replacement completes the same frozen gates.
- Validate the instrument with coordinated-negation and case-sensitive technical-token controls.
- Read at least one actual output from every route before accepting counters.
- Publish aggregate results only; private audio/text and provider responses stay outside the repository.
