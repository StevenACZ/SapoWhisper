# 🐸 SapoWhisper

**Transcribe your voice to text with a keyboard shortcut.**

A macOS menu bar app that instantly converts speech to text. Press `⌥ + Space`, speak, and the text is automatically pasted wherever you're typing.

![macOS](https://img.shields.io/badge/macOS-14.0+-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift)
![License](https://img.shields.io/badge/License-MIT-green)

---

## ✨ Features

- 🎤 **Instant transcription** — Press the shortcut, speak, done
- 🔒 **100% private** — Local transcription option with WhisperKit (no internet needed)
- 🎙️ **Deepgram Nova-3** — High accuracy cloud transcription
- ☁️ **Google Cloud Chirp 3** — Maximum accuracy with Google's latest STT model
- 📋 **Transcription history** — Browse, search, pin, replay, and re-transcribe past recordings
- 🎛️ **Persistent preferred microphone** — Keep your chosen mic as the macOS global input even when switching between AirPods, speakers, or other output routes
- ⌨️ **Auto-paste** — Text is automatically pasted where you're typing
- 🌐 **Bilingual** — Supports Spanish and English
- 🎨 **Visual overlay** — Compact floating pill shows recording status
- 🔐 **Guided permissions** — Opens on launch when access is missing and guides you to the exact System Settings panel
- 🔄 **Re-transcribe** — Re-process any saved recording with a different engine
- 💾 **Audio download** — Export your recordings from history
- 🔉 **Auto-ducking** — Automatically lowers system volume while recording so background audio doesn't interfere

---

## 🚀 Installation

### Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1/M2/M3/M4/M5) recommended

### Steps

1. Download the latest version from the repository Releases page
2. Drag `SapoWhisper.app` to your Applications folder
3. Open the app — a 🐸 will appear in your menu bar
4. If macOS needs access, SapoWhisper will open a guided **Missing Permissions** flow on launch and take you to the exact System Settings panel

---

## 🎯 Usage

1. **Press `⌥ + Space`** (Option + Space) — _customizable in Settings_
2. **Speak** — You'll see a floating pill with the audio equalizer
3. **Press the shortcut again** to stop
4. ✨ **Text is automatically pasted**

> 💡 You can change the shortcut in Settings → Hotkey

### Guided Permissions

If a required permission is missing, SapoWhisper opens a **Missing Permissions** window that:

- appears automatically on launch when setup is incomplete
- keeps every permission visible in one place
- shows live status updates (`Pending` / `Active`)
- opens the exact System Settings privacy panel for that permission
- shows a floating helper overlay on top of System Settings
- lets you drag the app into the Accessibility list if needed

### Pause & Resume

Click the pause button on the overlay pill to pause recording. Click again to resume — audio segments are concatenated seamlessly.

### Multi-Monitor

The overlay automatically appears on the screen where your mouse cursor is.

### Preferred Microphone Sync

If you choose a specific microphone in **Settings → General**, SapoWhisper keeps that device aligned with the macOS global input when audio routes change. If the microphone is unplugged or disappears, the app automatically falls back to **System Default**.

---

## ⚙️ Transcription Engines

Choose your preferred engine in **Settings → Engine**:

### Apple Speech (Online)

- ☁️ Requires internet connection
- 📦 No download needed
- 🔄 Uses Apple's servers

### WhisperKit (Local) — Recommended for privacy

- 🔒 **100% offline** — Your audio never leaves your Mac
- 📥 Models download automatically inside the app
- 🧠 Model memory released when switching to a cloud engine

| Model                 | Size   | Speed     | Accuracy   |
| --------------------- | ------ | --------- | ---------- |
| Tiny                  | 77 MB  | Very fast | ⭐⭐       |
| Base                  | 147 MB | Fast      | ⭐⭐⭐     |
| **Small** ⭐          | 487 MB | Moderate  | ⭐⭐⭐⭐   |
| Large V3              | 3.1 GB | Slow      | ⭐⭐⭐⭐⭐ |
| **Large V3 Turbo** ⭐ | 3.2 GB | Fast      | ⭐⭐⭐⭐⭐ |

> 💡 **Small** and **Large V3 Turbo** are recommended for best balance.

### Google Cloud (Online) — Best accuracy

- 🎯 **Chirp 3 (V2)** — Google's most accurate speech-to-text model
- 🔑 **API Key (V1)** — Simple alternative with `latest_long` model
- ☁️ Requires internet and a Google Cloud account

#### Chirp 3 Setup (Recommended)

```bash
# 1. Install gcloud CLI
brew install google-cloud-sdk

# 2. Authenticate
gcloud auth application-default login
```

SapoWhisper will automatically detect your credentials. That's it!

#### API Key Setup (Alternative)

1. Go to [Google Cloud Console](https://console.cloud.google.com) → APIs & Services → Credentials
2. Create an API Key and restrict it to **Cloud Speech-to-Text API**
3. Paste the key in SapoWhisper Settings → Engine → Google Cloud → API Key

### Deepgram — High accuracy

- 🎙️ **Nova-3** — Deepgram's most accurate model
- 📝 **Custom vocabulary** — Add keyterms and word replacements for better accuracy
- ☁️ Requires internet and a Deepgram API key

#### Setup

1. Create a free account at [deepgram.com](https://deepgram.com)
2. Go to Dashboard → API Keys → Create Key
3. Paste the key in SapoWhisper Settings → Engine → Deepgram → API Key

---

## 📋 Transcription History

Access your past transcriptions from the menu bar → **History**.

- **Browse** — Entries grouped by date (Today, Yesterday, This Week, etc.)
- **Search** — Filter by text content (debounced, SQL-powered)
- **Engine filter** — Show only entries from a specific engine with colored indicators
- **Pin** — Mark important transcriptions for quick access
- **Audio playback** — Replay saved audio recordings inline
- **Re-transcribe** — Pick any engine and re-process a saved recording
- **Download audio** — Export recordings to disk
- **Inspector** — View metadata (engine, language, duration, word count)
- **Real-time** — Window auto-refreshes after new transcriptions

> 💡 Audio is saved for all transcriptions (success and failure), so you can always re-transcribe or download later. SapoWhisper automatically removes orphan recordings and trims old audio when the history storage cap is reached.

---

## ⚡ Performance

SapoWhisper is optimized for low-latency operation:

| Metric | Time |
|--------|------|
| Hotkey → overlay visible | ~30ms |
| Overlay → audio recording | ~30ms |
| Total startup | ~240ms |
| Stop → text pasted | ~1.9s (Deepgram) |

Key optimizations:
- Overlay window pre-warmed on app launch
- Single `AVAudioEngine` for both recording and level metering
- Sound effects pre-cached in memory
- Audio recorded as int16 WAV (compact, no conversion needed for cloud upload)
- Deterministic overlay animations avoid long-session redraw churn
- Adaptive auto-paste (polls for target app instead of fixed delay)

---

## 🤝 Contributing

Contributions are welcome. If you find a bug or have an idea, open an issue in the repository.

---

## 📄 License

MIT
