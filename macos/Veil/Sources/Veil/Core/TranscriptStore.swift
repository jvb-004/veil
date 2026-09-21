//  Rolling transcript, tagged by source.
//
//  Speaker attribution here is not a diarisation model and does not need to be.
//  Far end came off the process tap, near end came off the microphone. Two
//  sockets, two labels, no guessing, no cost.

import Foundation

final class TranscriptStore {

    struct Line {
        var speaker: Speaker
        var text: String
        var at: Date
    }

    private(set) var lines: [Line] = []
    private var interim: [Speaker: String] = [:]
    private let maxLines = 60

    func apply(_ segment: TranscriptSegment) {
        if segment.isFinal {
            interim[segment.speaker] = nil
            let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lines.append(Line(speaker: segment.speaker, text: trimmed, at: segment.at))
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        } else {
            interim[segment.speaker] = segment.text
        }
    }

    func interimText(for speaker: Speaker) -> String { interim[speaker] ?? "" }

    /// What the model sees. Recent turns only: the far end asked one thing, and
    /// three minutes of small talk before it is noise that costs latency.
    func context(lastTurns: Int = 14) -> String {
        lines.suffix(lastTurns).map { line in
            let who = line.speaker == .farEnd ? "THEM" : "YOU"
            return "\(who): \(line.text)"
        }.joined(separator: "\n")
    }

    var lastFarEndLine: String? {
        lines.last(where: { $0.speaker == .farEnd })?.text
    }
}
