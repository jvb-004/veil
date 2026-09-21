//  Near-end capture. Your own voice, from the default input.
//
//  Kept separate from the tap on purpose: knowing who spoke matters more than
//  any diarisation model, and source separation gives it to us for free.

import AVFoundation
import Foundation

final class MicCapture {
    private let engine = AVAudioEngine()
    private var installed = false

    /// Called on an audio thread with mono float samples at `sampleRate`.
    var onSamples: (([Float], Double) -> Void)?

    func start() throws {
        guard !installed else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "veil.mic", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "input device reports a zero sample rate, usually no microphone permission"
            ])
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            self.onSamples?(samples, format.sampleRate)
        }
        installed = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        guard installed else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        installed = false
    }

    deinit { stop() }
}
