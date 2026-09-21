//  When to answer. This, not the overlay and not the flag, is the product.
//
//  Three jobs:
//
//  1. Decide that what just happened was a question aimed at you, rather than
//     the other person thinking out loud or a colleague interrupting.
//  2. Fire early, on an interim transcript, so the first token is on screen
//     before the sentence has finished. This is the entire latency budget.
//  3. Take it back cheaply when the speculation was wrong, which it sometimes
//     will be, because being occasionally wrong quickly beats being reliably
//     right too late.

import Foundation

final class Trigger {

    struct Decision {
        var text: String
        var speculative: Bool
    }

    /// Fired when the model should be asked. `speculative` answers may be
    /// superseded; the caller cancels the previous stream.
    var onFire: ((Decision) -> Void)?

    private var lastInterim = ""
    private var lastInterimAt = Date.distantPast
    private var lastFiredText = ""
    private var lastFiredAt = Date.distantPast
    private var speculationOutstanding = false

    private let stabilityWindow: TimeInterval = 0.25   // interim must hold still
    private let debounce: TimeInterval = 1.2           // do not machine-gun the API
    private let minimumWords = 4

    // MARK: interim path (speculative)

    func considerInterim(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastInterim else {
            // Held still long enough, and it reads like a question? Go early.
            if !speculationOutstanding,
               Date().timeIntervalSince(lastInterimAt) >= stabilityWindow,
               looksLikeAQuestion(trimmed),
               wordCount(trimmed) >= minimumWords,
               Date().timeIntervalSince(lastFiredAt) >= debounce {
                speculationOutstanding = true
                fire(trimmed, speculative: true)
            }
            return
        }
        lastInterim = trimmed
        lastInterimAt = Date()
    }

    // MARK: final path (authoritative)

    func considerFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastInterim = ""
        speculationOutstanding = false
        guard wordCount(trimmed) >= 2 else { return }

        // If the speculation already covered this, do not pay for it twice.
        if !lastFiredText.isEmpty, similarity(trimmed, lastFiredText) > 0.85 { return }
        guard looksLikeAQuestion(trimmed) || isImperative(trimmed) else { return }
        fire(trimmed, speculative: false)
    }

    /// Manual override. Sometimes you just want an answer.
    func fireManually(_ text: String) { fire(text, speculative: false) }

    private func fire(_ text: String, speculative: Bool) {
        lastFiredText = text
        lastFiredAt = Date()
        onFire?(Decision(text: text, speculative: speculative))
    }

    // MARK: heuristics

    private func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }

    private static let interrogatives: Set<String> = [
        "what", "why", "how", "when", "where", "who", "which", "whose",
        "can", "could", "would", "should", "do", "does", "did", "is", "are",
        "was", "were", "will", "have", "has", "am", "may", "might",
    ]

    private func looksLikeAQuestion(_ text: String) -> Bool {
        if text.hasSuffix("?") { return true }
        guard let first = text.lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .first.map(String.init)
        else { return false }
        return Self.interrogatives.contains(first)
    }

    private static let imperatives = [
        "tell me", "walk me through", "explain", "describe", "give me",
        "talk about", "let's talk", "i'd like to hear", "go over",
    ]

    private func isImperative(_ text: String) -> Bool {
        let lower = text.lowercased()
        return Self.imperatives.contains { lower.contains($0) }
    }

    /// Cheap token overlap. Enough to answer "is this the same question".
    private func similarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.lowercased().split(separator: " "))
        let setB = Set(b.lowercased().split(separator: " "))
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        return Double(setA.intersection(setB).count) / Double(max(setA.count, setB.count))
    }
}
