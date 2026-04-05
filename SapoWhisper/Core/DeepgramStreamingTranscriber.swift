//
//  DeepgramStreamingTranscriber.swift
//  SapoWhisper
//

import AVFoundation
import Combine
import Foundation

/// Real-time streaming transcription via Deepgram Nova-3 WebSocket
class DeepgramStreamingTranscriber: ObservableObject {

    @Published var partialTranscript: String = ""
    @Published var finalTranscript: String = ""
    @Published var isConnected: Bool = false
    @Published var isTranscribing: Bool = false
    @Published var connectionError: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketSession: URLSession?
    private var keepAliveTimer: Timer?
    private var isStopping = false

    /// Check if Deepgram API key is configured
    var isConfigured: Bool {
        let key = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey) ?? ""
        return !key.isEmpty
    }

    // MARK: - Connection

    /// Open WebSocket connection to Deepgram
    func connect(language: String) {
        guard !isConnected else { return }

        guard let apiKey = UserDefaults.standard.string(forKey: Constants.StorageKeys.deepgramAPIKey),
              !apiKey.isEmpty else {
            DispatchQueue.main.async { self.connectionError = "Deepgram API key not configured" }
            return
        }

        // Build URL with query parameters
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "language", value: deepgramLanguageCode(for: language)),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "utterance_end_ms", value: "1000"),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
        ]

        // Add vocabulary
        queryItems.append(contentsOf: VocabularyManager.shared.keytermQueryItems())
        queryItems.append(contentsOf: VocabularyManager.shared.replaceQueryItems())

        components.queryItems = queryItems

        guard let url = components.url else { return }

        // Use a dedicated URLSession with auth in httpAdditionalHeaders
        // URLSessionWebSocketTask sometimes drops custom headers from URLRequest
        // during the WebSocket upgrade handshake
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "Authorization": "Token \(apiKey)"
        ]
        webSocketSession = URLSession(configuration: config)
        webSocketTask = webSocketSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        // Set isConnected immediately so sendAudioBuffer can start sending.
        // Deepgram needs audio before it sends any response — waiting for first
        // receive would deadlock. Connection errors are caught in startReceiving.
        isConnected = true
        isTranscribing = true
        isStopping = false
        partialTranscript = ""
        finalTranscript = ""
        connectionError = nil

        startReceiving()
        startKeepAlive()

        print("Deepgram WebSocket connecting: \(deepgramLanguageCode(for: language))")
    }

    /// Fix #3: Async disconnect that waits for final results
    func disconnect() async -> String {
        guard !isStopping else { return finalTranscript }
        isStopping = true

        // Send CloseStream
        let closeMessage = URLSessionWebSocketTask.Message.string("{\"type\": \"CloseStream\"}")
        try? await webSocketTask?.send(closeMessage)

        // Wait up to 2 seconds for final results
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && isConnected {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Now clean up
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        webSocketSession?.invalidateAndCancel()
        webSocketSession = nil
        isConnected = false
        isTranscribing = false

        print("Deepgram WebSocket disconnected")
        return finalTranscript
    }

    // MARK: - Send Audio

    /// Send a float32 audio buffer as LINEAR16 via WebSocket
    func sendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isConnected, let floatData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        var int16Data = Data(count: frameCount * 2)
        int16Data.withUnsafeMutableBytes { raw in
            let buf = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                buf[i] = Int16(max(-1.0, min(1.0, floatData[0][i])) * 32767.0)
            }
        }

        let message = URLSessionWebSocketTask.Message.data(int16Data)
        webSocketTask?.send(message) { error in
            if let error = error {
                print("Deepgram send error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Receive Results

    // Fix #7, #8: Report errors and detect connection state
    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, !self.isStopping else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.startReceiving()

            case .failure(let error):
                // Clean up resources on connection failure
                self.keepAliveTimer?.invalidate()
                self.keepAliveTimer = nil
                self.webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
                self.webSocketTask = nil
                self.webSocketSession?.invalidateAndCancel()
                self.webSocketSession = nil

                DispatchQueue.main.async {
                    self.isConnected = false
                    self.isTranscribing = false
                    self.connectionError = error.localizedDescription
                }
            }
        }
    }

    // Fix #17: Handle speech_final for paragraph breaks
    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "Results" {
            guard let channel = json["channel"] as? [String: Any],
                  let alternatives = channel["alternatives"] as? [[String: Any]],
                  let transcript = alternatives.first?["transcript"] as? String else { return }

            let isFinal = json["is_final"] as? Bool ?? false
            let speechFinal = json["speech_final"] as? Bool ?? false

            DispatchQueue.main.async {
                if isFinal {
                    if !transcript.isEmpty {
                        if !self.finalTranscript.isEmpty {
                            // Use newline on speech_final (end of utterance), space otherwise
                            self.finalTranscript += speechFinal ? "\n" : " "
                        }
                        self.finalTranscript += transcript
                    }
                    self.partialTranscript = self.finalTranscript
                } else {
                    if transcript.isEmpty {
                        self.partialTranscript = self.finalTranscript
                    } else if self.finalTranscript.isEmpty {
                        self.partialTranscript = transcript
                    } else {
                        self.partialTranscript = self.finalTranscript + " " + transcript
                    }
                }
            }
        }
    }

    // MARK: - KeepAlive

    // Fix #21: KeepAlive on main RunLoop explicitly
    private func startKeepAlive() {
        DispatchQueue.main.async { [weak self] in
            self?.keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isConnected else { return }
                let msg = URLSessionWebSocketTask.Message.string("{\"type\": \"KeepAlive\"}")
                self.webSocketTask?.send(msg) { _ in }
            }
        }
    }

    // MARK: - Language Mapping

    private func deepgramLanguageCode(for appLanguage: String) -> String {
        switch appLanguage {
        case "es": return "es"
        case "en": return "en"
        case "auto": return "multi"
        default: return "es"
        }
    }
}
