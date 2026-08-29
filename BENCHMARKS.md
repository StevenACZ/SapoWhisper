# SapoWhisper Benchmarks

This file is the public, aggregate scorecard for engine and AI-model decisions. It contains no user transcripts, recordings, vocabulary, local paths, account data, or private corpus fingerprints.

## Promotion Rules

1. Freeze the prompt, synthetic/public corpus, model ID, reasoning setting, and runner hash.
2. Run Normal, Compact, Normal + translation, and Compact + translation four times each.
3. Require zero uncompensated critical failures: semantic loss, inverted or missing negation, digit/name/path drift, wrong language, invalid output, runtime failure, instability, added answers, or collapse.
4. A short screen may reject a model but cannot fully promote it. Universal recommendations must also pass the long-input gates.
5. Compare latency and price only after fidelity passes.

## AI Polish Short Screen

Snapshot: 2026-08-29. One fully synthetic Spanish case, four routes, four repetitions, 16 records per model. Reasoning was disabled. Prices are USD per million tokens from the [OpenRouter models API](https://openrouter.ai/api/v1/models) on that date and will drift.

| Model | Input / output | p50 | Evidence |
|---|---:|---:|---|
| anthropic/claude-opus-5 | $5.00 / $25.00 | 9.32 s | **16/16 critical pass**, including both translation routes. Best tested; long 14/40-minute gates pending. |
| z-ai/glm-5.3-flash | $0.075 / $0.25 | 23.57 s | Rejected: language and runtime failures. |
| qwen/qwen3.8-flash | $0.15 / $0.47 | 9.05 s | Conditional same-language value candidate; failed all 8 translation records and had runtime instability. |
| openai/gpt-5.6-sol | $2.00 / $10.00 | 11.75 s | Rejected: semantic and case-sensitive technical-token drift plus translation/runtime failures. |
| openai/gpt-5.4-nano | $0.20 / $1.25 | 6.13 s | Fast budget candidate; rejected as universal because hard Compact/translation records lost content or language. |
| deepseek/deepseek-v4-flash-0731 | $0.045 / $0.09 | 25.64 s | Rejected: requirements, negations, digits, names, paths, translation, stability, and collapse. |
| openai/gpt-5.6-luna | $0.20 / $1.20 | 8.81 s | Rejected: semantic, translation, runtime, and stability failures. |
| qwen/qwen3.5-flash-02-23 | $0.065 / $0.26 | 8.47 s | Economy only; rejected for important text because fidelity, translation, runtime, and stability gates failed. |

### User-facing tiers

- **Best tested:** Claude Opus 5. Use when fidelity and translation matter more than cost.
- **Same-language value:** Qwen 3.8 Flash. Do not select it for translation.
- **Fast budget:** GPT-5.4 Nano. SapoWhisper's guards may keep the source text on hard cases.
- **Economy:** Qwen 3.5 Flash. Avoid for important instructions and translation.
- **Local AI polish:** experimental. No small local refiner currently qualifies as a recommendation.

SapoWhisper keeps the model field free-form because provider catalogs change. A model absent from this table is unranked, not implicitly safe.

## Speech-to-Text Public Fixtures

Four repetitions over the unchanged public English fixtures:

| Engine | Corrected English WER |
|---|---:|
| Deepgram Nova-3 with production context | **1.149%** |
| faster-whisper Large V3 Turbo (FP16, NVIDIA) | 3.831% |

Nova-3 leads this small public English WER set. The previous Spanish natural-voice fixture was removed from the repository and replaced by a system-generated public fixture; no Spanish score is published until the replacement completes the same four-repeat matrix. Turbo remains the local offline/LAN baseline. Deepgram Flux Live is the responsiveness choice and preserves a WAV for fallback; its close path accepts only a normal provider socket termination and otherwise uses the WAV fallback.

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
