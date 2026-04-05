# 🐸 SapoWhisper

**Transcribe your voice to text with a keyboard shortcut.**

A macOS menu bar app that instantly converts speech to text. Press `⌥ + Space`, speak, and the text is automatically pasted wherever you're typing.

![macOS](https://img.shields.io/badge/macOS-13.0+-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)
![License](https://img.shields.io/badge/License-MIT-green)

---

## ✨ Features

- 🎤 **Instant transcription** — Press the shortcut, speak, done
- 🔒 **100% private** — Local transcription option with WhisperKit (no internet needed)
- 🎙️ **Real-time streaming** — Deepgram Nova-3 shows text as you speak
- ☁️ **Google Cloud Chirp 3** — Maximum accuracy with Google's latest STT model
- ⌨️ **Auto-paste** — Text is automatically pasted where you're typing
- 🌐 **Bilingual** — Supports Spanish and English
- 🎨 **Visual overlay** — Compact floating pill shows recording status

---

## 🚀 Installation

### Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1/M2/M3/M4/M5) recommended

### Steps

1. Download the latest version from [Releases](https://github.com/StevenACZ/SapoWhisper/releases)
2. Drag `SapoWhisper.app` to your Applications folder
3. Open the app — a 🐸 will appear in your menu bar
4. Grant microphone permissions when prompted

---

## 🎯 Usage

1. **Press `⌥ + Space`** (Option + Space) — _customizable in Settings_
2. **Speak** — You'll see a floating pill with the audio equalizer
3. **Press the shortcut again** to stop
4. ✨ **Text is automatically pasted**

> 💡 You can change the shortcut in Settings → Hotkey

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

### Deepgram (Streaming) — Real-time transcription

- 🎙️ **Nova-3** — Deepgram's most accurate model with real-time streaming
- ⚡ **Live text** — See words appear as you speak via WebSocket
- 📝 **Custom vocabulary** — Add keyterms and word replacements for better accuracy
- ☁️ Requires internet and a Deepgram API key

#### Setup

1. Create a free account at [deepgram.com](https://deepgram.com)
2. Go to Dashboard → API Keys → Create Key
3. Paste the key in SapoWhisper Settings → Engine → Deepgram → API Key

---

## 🤝 Contributing

Contributions are welcome! If you find a bug or have an idea, open an [Issue](https://github.com/StevenACZ/SapoWhisper/issues).

---

## 📄 License

MIT © [StevenACZ](https://github.com/StevenACZ)
