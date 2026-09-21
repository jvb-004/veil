//! Whatever the device felt like, down to 16 kHz mono linear16.
//!
//! Linux does not need this: pw-record already emits the right format. Windows
//! does, because WASAPI hands you the device's native mix format, which is
//! usually 48 kHz stereo float32 and occasionally something stranger.
//!
//! Linear interpolation is not audiophile resampling. At 16 kHz, for speech
//! recognition, it is inaudible in the word error rate and costs nothing.

/// Interleaved multi-channel to mono, by averaging.
pub fn to_mono(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    interleaved
        .chunks_exact(channels)
        .map(|frame| frame.iter().sum::<f32>() / channels as f32)
        .collect()
}

pub fn resample(input: &[f32], source_rate: f64, target_rate: f64) -> Vec<f32> {
    if input.is_empty() || source_rate <= 0.0 || target_rate <= 0.0 {
        return Vec::new();
    }
    if (source_rate - target_rate).abs() < 1.0 {
        return input.to_vec();
    }
    let ratio = source_rate / target_rate;
    let count = (input.len() as f64 / ratio) as usize;
    (0..count)
        .map(|i| {
            let position = i as f64 * ratio;
            let low = position as usize;
            let high = (low + 1).min(input.len() - 1);
            let fraction = (position - low as f64) as f32;
            input[low] * (1.0 - fraction) + input[high] * fraction
        })
        .collect()
}

/// Little-endian signed 16-bit, which is what `encoding=linear16` means.
pub fn to_linear16(samples: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        let clamped = sample.clamp(-1.0, 1.0);
        out.extend_from_slice(&((clamped * 32767.0) as i16).to_le_bytes());
    }
    out
}

/// The whole chain, for feeding a socket.
pub fn prepare(interleaved: &[f32], channels: usize, source_rate: f64) -> Vec<u8> {
    let mono = to_mono(interleaved, channels);
    let resampled = resample(&mono, source_rate, 16000.0);
    to_linear16(&resampled)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stereo_averages_to_mono() {
        assert_eq!(to_mono(&[1.0, 0.0, 0.5, 0.5], 2), vec![0.5, 0.5]);
    }

    #[test]
    fn downsampling_shortens_by_the_ratio() {
        let input: Vec<f32> = (0..4800).map(|i| (i as f32 / 100.0).sin()).collect();
        let out = resample(&input, 48000.0, 16000.0);
        assert_eq!(out.len(), 1600);
    }

    #[test]
    fn same_rate_is_a_passthrough() {
        let input = vec![0.1, 0.2, 0.3];
        assert_eq!(resample(&input, 16000.0, 16000.0), input);
    }

    #[test]
    fn linear16_is_little_endian_and_clamped() {
        assert_eq!(to_linear16(&[0.0]), vec![0, 0]);
        assert_eq!(to_linear16(&[2.0]), 32767i16.to_le_bytes().to_vec());
        assert_eq!(to_linear16(&[-2.0]), (-32767i16).to_le_bytes().to_vec());
    }

    #[test]
    fn the_whole_chain_produces_two_bytes_per_output_sample() {
        let input: Vec<f32> = vec![0.25; 9600]; // 4800 stereo frames at 48k = 100ms
        let bytes = prepare(&input, 2, 48000.0);
        assert_eq!(bytes.len(), 1600 * 2);
    }
}
