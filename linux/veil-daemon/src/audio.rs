//! Audio capture on Linux, which is the easy part.
//!
//! No driver, no kernel extension, no TCC prompt, no virtual device. The far
//! end of the call is already sitting on the default sink's monitor source,
//! and PipeWire will hand it over in exactly the format the ASR wants.
//!
//! This shells out to pw-record on purpose for now. It is one dependency-free
//! process that already does capture, channel mixdown and resampling correctly,
//! which means there is no resampler in this codebase to get subtly wrong.
//! Swapping in pipewire-rs later is an implementation detail behind this API.

use anyhow::{Context, Result};
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};
use tokio::sync::mpsc;

/// ~100ms of 16 kHz mono s16. Small enough to keep latency low, large enough
/// that we are not waking the runtime every other millisecond.
const CHUNK_BYTES: usize = 3200;

pub struct Capture {
    /// Held so the recorder outlives this struct's owner. kill_on_drop means
    /// letting go of this is what stops the capture.
    child: Child,
}

impl Capture {
    pub fn start(
        target: Option<&str>,
        label: &'static str,
    ) -> Result<(Self, mpsc::Receiver<Vec<u8>>)> {
        let mut command = Command::new("pw-record");
        command
            .arg("--format=s16")
            .arg("--rate=16000")
            .arg("--channels=1")
            .arg("--raw");
        if let Some(target) = target {
            command.arg(format!("--target={target}"));
        }
        command.arg("-"); // stdout

        let mut child = command
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .context("pw-record not found; install pipewire-utils")?;

        let mut stdout = child.stdout.take().context("pw-record stdout")?;
        let (tx, rx) = mpsc::channel(32);

        tokio::spawn(async move {
            let mut buffer = vec![0u8; CHUNK_BYTES];
            loop {
                match stdout.read(&mut buffer).await {
                    Ok(0) => break,
                    Ok(n) => {
                        if tx.send(buffer[..n].to_vec()).await.is_err() {
                            break;
                        }
                    }
                    Err(e) => {
                        tracing::warn!("{label} capture read failed: {e}");
                        break;
                    }
                }
            }
            tracing::info!("{label} capture ended");
        });

        Ok((Self { child }, rx))
    }

    pub async fn stop(mut self) {
        let _ = self.child.kill().await;
    }
}

/// The default sink's monitor, resolved by name so the config can stay empty.
pub fn default_monitor() -> Option<String> {
    let output = std::process::Command::new("pactl")
        .args(["get-default-sink"])
        .output()
        .ok()?;
    let sink = String::from_utf8(output.stdout).ok()?.trim().to_string();
    (!sink.is_empty()).then(|| format!("{sink}.monitor"))
}
