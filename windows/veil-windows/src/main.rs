//! veil, Windows.
//!
//!   render endpoint loopback -> Deepgram -> trigger -> Claude -> overlay
//!   microphone               -> Deepgram -> transcript
//!
//! The overlay owns the main thread because a Win32 message loop insists on
//! it, so the pipeline runs on a Tokio runtime beside it and pushes text in.

#![cfg_attr(not(windows), allow(dead_code))]

#[cfg(windows)]
mod audio;
#[cfg(windows)]
mod overlay;
#[cfg(windows)]
mod watchdog;

#[cfg(not(windows))]
fn main() {
    eprintln!("veil-windows only builds for Windows targets");
}

#[cfg(windows)]
fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()))
        .init();

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    runtime.spawn(pipeline());

    // The window does not exist until the message loop below creates it, so
    // the watchdog waits for the handle rather than racing it.
    std::thread::spawn(|| {
        let Some(handle) = overlay::wait_for_window(std::time::Duration::from_secs(5)) else {
            tracing::error!("overlay never appeared; watchdog not started");
            return;
        };
        let mut hidden = false;
        for state in watchdog::spawn(handle) {
            if state.exclusion_checked && !state.exclusion_holding {
                // The flag is lying. This is the exact case the design exists
                // for, so it is loud rather than silent.
                tracing::error!("capture exclusion is NOT working; hiding overlay");
            }
            for reason in &state.reasons {
                tracing::info!("watchdog: {reason}");
            }
            if state.capture_suspected != hidden {
                hidden = state.capture_suspected;
                overlay::set_visible(!hidden);
            }
        }
    });

    // Blocks until the window closes.
    overlay::run(520, 240)
}

#[cfg(windows)]
async fn pipeline() {
    use veil_core::{Claude, Config, Deepgram, Speaker, Transcript, Trigger};

    let config = Config::load();
    overlay::set_text(&format!("veil 0.1.0\nmodel {}", config.model));

    let Some(deepgram_key) = config.deepgram_api_key.clone() else {
        overlay::set_text("DEEPGRAM_API_KEY is not set");
        return;
    };

    let far_audio = match audio::far_end() {
        Ok(rx) => rx,
        Err(e) => {
            overlay::set_text(&format!("far-end capture failed:\n{e}"));
            return;
        }
    };
    let near_audio = match audio::near_end() {
        Ok(rx) => rx,
        Err(e) => {
            tracing::warn!("microphone unavailable: {e:#}");
            tokio::sync::mpsc::channel(1).1
        }
    };

    let mut far_segments = Deepgram::spawn(
        deepgram_key.clone(),
        Speaker::FarEnd,
        config.stt_model.clone(),
        config.language.clone(),
        far_audio,
    );
    let mut near_segments = Deepgram::spawn(
        deepgram_key,
        Speaker::NearEnd,
        config.stt_model.clone(),
        config.language.clone(),
        near_audio,
    );

    let answerer = config.anthropic_api_key.clone().map(|key| {
        Claude::new(
            key,
            config.model.clone(),
            config.persona.clone(),
            config.user_context(),
        )
    });
    if answerer.is_none() {
        overlay::set_text("ANTHROPIC_API_KEY is not set; transcribing only");
    }

    let mut transcript = Transcript::default();
    let mut trigger = Trigger::default();
    let mut answer_stream: Option<tokio::sync::mpsc::Receiver<String>> = None;
    let mut question = String::new();
    let mut body = String::new();

    loop {
        tokio::select! {
            Some(segment) = far_segments.recv() => {
                transcript.apply(&segment);
                let decision = if segment.is_final {
                    trigger.consider_final(&segment.text)
                } else {
                    trigger.consider_interim(&segment.text)
                };
                if let (Some(decision), Some(claude)) = (decision, answerer.as_ref()) {
                    // Dropping the previous receiver cancels the previous answer,
                    // which is how a speculative guess is superseded for free.
                    question = decision.text.clone();
                    body.clear();
                    answer_stream = Some(claude.answer(decision.text, transcript.context(14)));
                    overlay::set_text(&question);
                }
            }
            Some(segment) = near_segments.recv() => {
                transcript.apply(&segment);
            }
            Some(token) = async {
                match answer_stream.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending::<Option<String>>().await,
                }
            } => {
                body.push_str(&token);
                overlay::set_text(&format!("{question}\n\n{body}"));
            }
        }
    }
}
