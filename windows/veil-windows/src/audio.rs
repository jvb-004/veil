//! WASAPI capture.
//!
//! Far end comes off the default RENDER endpoint in loopback: whatever the
//! speakers are playing, which is the other person's voice. No driver, no
//! virtual cable, no permission prompt, same as Linux and unlike macOS before
//! 14.4.
//!
//! One honest limitation versus the macOS target: this is endpoint loopback,
//! so it captures everything the machine plays, not just the call. Windows can
//! do per-process loopback (ActivateAudioInterfaceAsync with
//! AUDIOCLIENT_ACTIVATION_PARAMS) which would let us tap Zoom alone, and that
//! matters the moment we add text to speech, because otherwise the assistant
//! would transcribe its own voice back into the transcript. Until then, the
//! simple path is the right one.

#![cfg(windows)]

use std::collections::VecDeque;

use anyhow::{Context, Result};
use tokio::sync::mpsc;
use wasapi::{initialize_mta, DeviceEnumerator, Direction, SampleType, StreamMode, WaveFormat};

/// What the ASR wants, asked for directly. WASAPI's own converter does the
/// resampling when it can, which beats doing it ourselves.
const TARGET_RATE: usize = 16000;
const TARGET_CHANNELS: usize = 1;
const TARGET_BITS: usize = 16;

pub fn spawn(direction: Direction, label: &'static str) -> Result<mpsc::Receiver<Vec<u8>>> {
    let (tx, rx) = mpsc::channel(32);

    std::thread::Builder::new()
        .name(format!("veil-audio-{label}"))
        .spawn(move || {
            if let Err(e) = capture_loop(direction, label, tx) {
                tracing::error!("{label} capture stopped: {e:#}");
            }
        })
        .context("spawn capture thread")?;

    Ok(rx)
}

fn capture_loop(direction: Direction, label: &str, tx: mpsc::Sender<Vec<u8>>) -> Result<()> {
    initialize_mta().ok().context("COM init")?;

    let enumerator = DeviceEnumerator::new().context("device enumerator")?;
    // Render + Capture direction is how wasapi-rs expresses loopback: we want
    // what the speakers are playing, not what a microphone hears.
    let device = enumerator
        .get_default_device(&direction)
        .context("default device")?;
    let mut client = device.get_iaudioclient().context("audio client")?;

    let format = WaveFormat::new(
        TARGET_BITS,
        TARGET_BITS,
        &SampleType::Int,
        TARGET_RATE,
        TARGET_CHANNELS,
        None,
    );
    let block_align = format.get_blockalign() as usize;

    let mode = StreamMode::EventsShared {
        autoconvert: true,
        buffer_duration_hns: 2_000_000, // 200ms of slack, we read far faster
    };
    client
        .initialize_client(&format, &Direction::Capture, &mode)
        .context("initialize_client; the endpoint may refuse 16 kHz mono")?;

    let event = client.set_get_eventhandle().context("event handle")?;
    let capture = client.get_audiocaptureclient().context("capture client")?;

    let mut queue: VecDeque<u8> = VecDeque::new();
    client.start_stream().context("start stream")?;
    tracing::info!("{label} capture running at {TARGET_RATE} Hz mono s16");

    // ~100ms. Low enough for latency, large enough not to thrash the runtime.
    let chunk = TARGET_RATE / 10 * block_align;

    loop {
        capture
            .read_from_device_to_deque(&mut queue)
            .context("read from device")?;

        while queue.len() >= chunk {
            let bytes: Vec<u8> = queue.drain(..chunk).collect();
            if tx.blocking_send(bytes).is_err() {
                tracing::info!("{label} consumer went away");
                let _ = client.stop_stream();
                return Ok(());
            }
        }

        if event.wait_for_event(1000).is_err() {
            // A silent endpoint can legitimately go quiet; keep waiting rather
            // than tearing the stream down on the first timeout.
            tracing::debug!("{label} waiting for audio");
        }
    }
}

pub fn far_end() -> Result<mpsc::Receiver<Vec<u8>>> {
    spawn(Direction::Render, "far-end")
}

pub fn near_end() -> Result<mpsc::Receiver<Vec<u8>>> {
    spawn(Direction::Capture, "near-end")
}
