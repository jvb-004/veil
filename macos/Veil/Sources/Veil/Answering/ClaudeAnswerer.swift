//  Streaming answers from the Messages API, over raw HTTP.
//
//  Swift has no official Anthropic SDK, so this speaks the wire protocol
//  directly: POST /v1/messages with "stream": true and a Server-Sent Events
//  response. Tokens are pushed out the moment they arrive, because the user
//  starts reading the first line aloud while the rest is still generating.
//
//  Three deliberate choices:
//
//  - thinking is adaptive, effort is low. Thinking stays ON, which avoids the
//    documented failure modes of disabling it, while low effort keeps the
//    first token fast. This is the recommended way to trade depth for latency.
//  - max_tokens is 700, far below the usual streaming default. The hard reason:
//    the output is read aloud in real time. Anything past a few lines is not
//    just wasted, it is actively unusable.
//  - server-side fallbacks are on by default, so a refusal reroutes instead of
//    handing the user an empty overlay mid-sentence.

import Foundation

final class ClaudeAnswerer: Answerer {

    private let apiKey: String
    private let model: String
    private let persona: String
    private let userContext: String
    private var task: Task<Void, Never>?

    init(apiKey: String, model: String, persona: String, userContext: String) {
        self.apiKey = apiKey
        self.model = model
        self.persona = persona
        self.userContext = userContext
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func answer(question: String,
                transcript: String,
                onToken: @escaping (String) -> Void,
                onDone: @escaping (Result<Void, Error>) -> Void) {
        cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.stream(question: question, transcript: transcript, onToken: onToken)
                if !Task.isCancelled { onDone(.success(())) }
            } catch is CancellationError {
                // Superseded by a better question. Not an error.
            } catch {
                if !Task.isCancelled { onDone(.failure(error)) }
            }
        }
    }

    private var systemPrompt: String {
        """
        \(persona)

        You produce lines the user will read ALOUD, immediately, while the other \
        person is watching their face. Everything follows from that:

        - First line is the answer itself, in at most 12 words. No preamble, no \
          "Great question", no restating what was asked.
        - Then at most three short supporting lines, each one a separate idea the \
          user can pick up or skip.
        - Spoken register. Contractions, plain words, no bullet syntax the user \
          would have to translate out loud, no markdown.
        - If it is a number, a name or a date, lead with it.
        - If you do not know, say so in one short line and offer the nearest thing \
          you do know. A confident wrong answer spoken out loud is the worst \
          possible outcome.

        \(userContext.isEmpty ? "" : "Background on the user and the subject:\n\(userContext)")
        """
    }

    private func stream(question: String,
                        transcript: String,
                        onToken: @escaping (String) -> Void) async throws {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        let userMessage = """
        Conversation so far (THEM is the other person, YOU is the user):
        \(transcript)

        Answer this, which THEM just asked:
        \(question)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 700,
            "stream": true,
            "system": systemPrompt,
            "thinking": ["type": "adaptive"],
            "output_config": ["effort": "low"],
            "fallbacks": "default",
            "messages": [["role": "user", "content": userMessage]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines { detail += line; if detail.count > 600 { break } }
            throw NSError(domain: "veil.claude", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(detail)"
            ])
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any],
                      (delta["type"] as? String) == "text_delta",
                      let text = delta["text"] as? String
                else { continue }
                onToken(text)

            case "message_delta":
                // stop_details is populated only on a refusal, so guard first.
                if let delta = event["delta"] as? [String: Any],
                   (delta["stop_reason"] as? String) == "refusal" {
                    let reason = (event["stop_details"] as? [String: Any])?["category"] as? String
                    onToken("\n[declined: \(reason ?? "unspecified")]")
                }

            case "error":
                let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "unknown"
                throw NSError(domain: "veil.claude", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: message])

            default:
                continue
            }
        }
    }
}
