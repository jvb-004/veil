//  Voice activity and endpointing.
//
//  Deliberately simple: RMS with hysteresis and a hangover. It is the cheapest
//  thing that turns a stream of audio into "somebody finished asking
//  something", which is all the trigger stage needs. Swapping in Silero later
//  is a one-protocol change, not a rewrite.

import Foundation

struct VADConfig {
    var frameMillis: Double = 30
    var speechThreshold: Float = 0.012      // RMS to open
    var silenceThreshold: Float = 0.006     // RMS to close, lower to avoid chatter
    var hangoverMillis: Double = 700        // silence before we call it a turn
    var minUtteranceMillis: Double = 350    // ignore coughs and keyboard clicks
}

final class VAD {
    private let config: VADConfig
    private var sampleRate: Double = 48000
    private var speaking = false
    private var silentMillis: Double = 0
    private var voicedMillis: Double = 0

    /// Fired once when a turn ends, with how long the turn was.
    var onTurnEnded: ((Double) -> Void)?
    var onSpeechStarted: (() -> Void)?

    private(set) var lastLevel: Float = 0

    init(config: VADConfig = VADConfig()) { self.config = config }

    func feed(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        self.sampleRate = sampleRate
        let frame = max(1, Int(sampleRate * config.frameMillis / 1000))
        var index = 0
        while index < samples.count {
            let end = min(index + frame, samples.count)
            let slice = samples[index..<end]
            let millis = Double(end - index) / sampleRate * 1000
            process(rms(slice), millis: millis)
            index = end
        }
    }

    private func rms(_ slice: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        for s in slice { sum += s * s }
        let value = (sum / Float(slice.count)).squareRoot()
        lastLevel = value
        return value
    }

    private func process(_ level: Float, millis: Double) {
        if speaking {
            if level < config.silenceThreshold {
                silentMillis += millis
                if silentMillis >= config.hangoverMillis {
                    let duration = voicedMillis
                    speaking = false
                    silentMillis = 0
                    voicedMillis = 0
                    if duration >= config.minUtteranceMillis { onTurnEnded?(duration) }
                }
            } else {
                silentMillis = 0
                voicedMillis += millis
            }
        } else if level > config.speechThreshold {
            speaking = true
            silentMillis = 0
            voicedMillis = millis
            onSpeechStarted?()
        }
    }
}
