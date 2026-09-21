//  Streaming ASR over a WebSocket.
//
//  Interim results are the point. They are what lets the trigger stage start
//  the model before the sentence has finished, which is the difference between
//  answering in two seconds and answering in five.

import Foundation

final class DeepgramTranscriber: NSObject, Transcriber, URLSessionWebSocketDelegate {

    var onSegment: ((TranscriptSegment) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let speaker: Speaker
    private let model: String
    private let language: String
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var keepAlive: Timer?

    init(apiKey: String, speaker: Speaker, model: String = "nova-3", language: String = "en") {
        self.apiKey = apiKey
        self.speaker = speaker
        self.model = model
        self.language = language
    }

    func start() throws {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            .init(name: "model", value: model),
            .init(name: "language", value: language),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "punctuate", value: "true"),
            .init(name: "smart_format", value: "true"),
            // Endpoint aggressively. A late final is a late answer.
            .init(name: "endpointing", value: "300"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let t = session.webSocketTask(with: request)
        task = t
        t.resume()
        receive()

        // Deepgram closes idle sockets at 10s; silence is common in a call.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.task?.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
    }

    func send(pcm16: Data) {
        guard !pcm16.isEmpty else { return }
        task?.send(.data(pcm16)) { [weak self] error in
            if let error { self?.onError?("deepgram send: \(error.localizedDescription)") }
        }
    }

    func finish() {
        task?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
    }

    func stop() {
        keepAlive?.invalidate()
        keepAlive = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.onError?("deepgram socket: \(error.localizedDescription)")
            case .success(let message):
                switch message {
                case .string(let text): self.handle(text)
                case .data(let data): self.handle(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handle(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        guard (object["type"] as? String) == "Results",
              let channel = object["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String,
              !transcript.isEmpty
        else { return }
        let isFinal = (object["is_final"] as? Bool) ?? false
        let speechFinal = (object["speech_final"] as? Bool) ?? false
        onSegment?(TranscriptSegment(speaker: speaker,
                                     text: transcript,
                                     isFinal: isFinal || speechFinal))
    }
}
