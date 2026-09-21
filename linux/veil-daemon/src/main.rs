//! veil daemon, Linux.
//!
//!   sink monitor -> pw-record -> Deepgram -> trigger -> Claude -> D-Bus
//!   microphone   -> pw-record -> Deepgram -> transcript
//!   PipeWire graph -> watchdog -> D-Bus
//!
//! Everything the user sees is drawn by the overlay process, because on GNOME
//! the compositor is the only thing that can put a window above a fullscreen
//! Zoom without stealing focus.

mod audio;
mod dbus;
mod watchdog;

use anyhow::{Context, Result};
use veil_core::{Claude, Config, Deepgram, Speaker, Transcript, Trigger};

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "info".into()))
        .init();

    let config = Config::load();
    tracing::info!("veil daemon 0.1.0, model {}", config.model);

    let connection = zbus::connection::Builder::session()?
        .name("dev.veil.Daemon")?
        .serve_at(
            "/dev/veil/Daemon",
            dbus::Daemon {
                version: "0.1.0".into(),
            },
        )?
        .build()
        .await
        .context("could not take the D-Bus name; is another daemon running?")?;
    let emitter = zbus::object_server::SignalEmitter::new(&connection, "/dev/veil/Daemon")?;

    // Capture. Far end first, because that is the one that matters.
    let far_target = config.far_target.clone().or_else(audio::default_monitor);
    tracing::info!(
        "far-end target: {}",
        far_target.as_deref().unwrap_or("(default)")
    );

    let (far_capture, far_audio) = audio::Capture::start(far_target.as_deref(), "far-end")?;
    let (near_capture, near_audio) =
        audio::Capture::start(config.near_target.as_deref(), "near-end")?;

    let Some(deepgram_key) = config.deepgram_api_key.clone() else {
        anyhow::bail!("DEEPGRAM_API_KEY is not set; nothing to transcribe with");
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
        tracing::warn!("ANTHROPIC_API_KEY is not set; transcribing only");
    }

    let mut share = watchdog::spawn();
    let mut transcript = Transcript::default();
    let mut trigger = Trigger::default();
    let mut answer_stream: Option<tokio::sync::mpsc::Receiver<String>> = None;
    let mut current_question = String::new();
    let mut current_body = String::new();
    let mut speculative = false;

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
                    // Dropping the old receiver cancels the old answer, which is
                    // how a speculative guess gets superseded without paying for it.
                    current_question = decision.text.clone();
                    current_body.clear();
                    speculative = decision.speculative;
                    answer_stream = Some(claude.answer(decision.text, transcript.context(14)));
                    let _ = dbus::Daemon::answer(&emitter, &current_question, "", speculative).await;
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
                current_body.push_str(&token);
                let _ = dbus::Daemon::answer(
                    &emitter, &current_question, &current_body, speculative).await;
            }

            Ok(()) = share.changed() => {
                let state = share.borrow().clone();
                let _ = dbus::Daemon::sharing(&emitter, state.sharing, state.scope.clone()).await;
                if state.sharing {
                    tracing::info!("screen capture active: {}", state.scope.join(", "));
                }
            }

            _ = tokio::signal::ctrl_c() => {
                tracing::info!("shutting down");
                break;
            }
        }
    }

    far_capture.stop().await;
    near_capture.stop().await;
    Ok(())
}
