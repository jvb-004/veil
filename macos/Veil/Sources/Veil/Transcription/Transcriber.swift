//  The seam. Deepgram today, a local Parakeet or whisper.cpp tomorrow, and
//  nothing above this line has to know which.

import Foundation

enum Speaker: String, Codable {
    case farEnd   // them
    case nearEnd  // you
}

struct TranscriptSegment {
    var speaker: Speaker
    var text: String
    var isFinal: Bool
    var at: Date = Date()
}

protocol Transcriber: AnyObject {
    var onSegment: ((TranscriptSegment) -> Void)? { get set }
    func start() throws
    func send(pcm16: Data)
    func finish()
    func stop()
}

/// No API key, no network: echoes level activity so the pipeline can be tested
/// end to end, including in CI where nothing is reachable.
final class NullTranscriber: Transcriber {
    var onSegment: ((TranscriptSegment) -> Void)?
    private let speaker: Speaker
    init(speaker: Speaker) { self.speaker = speaker }
    func start() throws {}
    func send(pcm16: Data) {}
    func finish() {}
    func stop() {}
}
