//  Float32 at whatever the device felt like, down to 16 kHz mono linear16,
//  which is what every streaming ASR endpoint actually wants.
//
//  Linear interpolation is not audiophile resampling. For speech recognition
//  at 16 kHz it is inaudible in the error rate and costs nothing.

import Foundation

enum Resampler {

    static func toMono(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        var out = [Float]()
        out.reserveCapacity(interleaved.count / channels)
        var i = 0
        while i + channels <= interleaved.count {
            var sum: Float = 0
            for c in 0..<channels { sum += interleaved[i + c] }
            out.append(sum / Float(channels))
            i += channels
        }
        return out
    }

    static func resample(_ input: [Float], from source: Double, to target: Double) -> [Float] {
        guard source > 0, target > 0, !input.isEmpty else { return [] }
        if abs(source - target) < 1 { return input }
        let ratio = source / target
        let count = Int(Double(input.count) / ratio)
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) * ratio
            let low = Int(position)
            let high = min(low + 1, input.count - 1)
            let fraction = Float(position - Double(low))
            out[i] = input[low] * (1 - fraction) + input[high] * fraction
        }
        return out
    }

    /// Little-endian signed 16-bit, which is what `encoding=linear16` means.
    static func toLinear16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32767)
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// The whole chain, for feeding a socket.
    static func prepare(_ interleaved: [Float], channels: Int, sourceRate: Double) -> Data {
        let mono = toMono(interleaved, channels: channels)
        let resampled = resample(mono, from: sourceRate, to: 16000)
        return toLinear16(resampled)
    }
}
