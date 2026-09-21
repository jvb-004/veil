//! Streaming ASR over a WebSocket.
//!
//! Interim results are the whole point: they are what lets the trigger stage
//! start the model before the sentence is finished.

use anyhow::{Context, Result};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;

use crate::transcript::{Segment, Speaker};

pub struct Deepgram;

impl Deepgram {
    /// Spawns the socket. Audio goes in on `audio_rx`, segments come out on the
    /// returned receiver. Both halves die together when either side drops.
    pub fn spawn(
        api_key: String,
        speaker: Speaker,
        model: String,
        language: String,
        mut audio_rx: mpsc::Receiver<Vec<u8>>,
    ) -> mpsc::Receiver<Segment> {
        let (segment_tx, segment_rx) = mpsc::channel(64);

        tokio::spawn(async move {
            let url = format!(
                "wss://api.deepgram.com/v1/listen?model={model}&language={language}\
                 &encoding=linear16&sample_rate=16000&channels=1\
                 &interim_results=true&punctuate=true&smart_format=true&endpointing=300"
            );
            let socket = match connect(&url, &api_key).await {
                Ok(s) => s,
                Err(e) => {
                    tracing::error!("deepgram connect failed: {e:#}");
                    return;
                }
            };
            let (mut write, mut read) = socket.split();

            // Deepgram closes idle sockets at 10s and calls are full of silence.
            let mut keepalive = tokio::time::interval(std::time::Duration::from_secs(5));

            loop {
                tokio::select! {
                    chunk = audio_rx.recv() => match chunk {
                        Some(bytes) => {
                            if write.send(Message::Binary(bytes)).await.is_err() { break; }
                        }
                        None => {
                            let _ = write.send(Message::Text(
                                r#"{"type":"CloseStream"}"#.into())).await;
                            break;
                        }
                    },
                    _ = keepalive.tick() => {
                        if write.send(Message::Text(r#"{"type":"KeepAlive"}"#.into()))
                            .await.is_err() { break; }
                    },
                    incoming = read.next() => match incoming {
                        Some(Ok(Message::Text(text))) => {
                            if let Some(segment) = parse(&text, speaker) {
                                if segment_tx.send(segment).await.is_err() { break; }
                            }
                        }
                        Some(Ok(_)) => {}
                        Some(Err(e)) => { tracing::warn!("deepgram socket: {e}"); break; }
                        None => break,
                    },
                }
            }
            tracing::info!("deepgram stream for {:?} closed", speaker);
        });

        segment_rx
    }
}

async fn connect(
    url: &str,
    api_key: &str,
) -> Result<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
> {
    let mut request = url.into_client_request().context("bad deepgram url")?;
    request.headers_mut().insert(
        "Authorization",
        format!("Token {api_key}")
            .parse()
            .context("bad api key header")?,
    );
    let (socket, _) = tokio_tungstenite::connect_async(request)
        .await
        .context("deepgram handshake")?;
    Ok(socket)
}

fn parse(raw: &str, speaker: Speaker) -> Option<Segment> {
    let value: serde_json::Value = serde_json::from_str(raw).ok()?;
    if value.get("type")?.as_str()? != "Results" {
        return None;
    }
    let text = value
        .get("channel")?
        .get("alternatives")?
        .get(0)?
        .get("transcript")?
        .as_str()?;
    if text.is_empty() {
        return None;
    }
    let is_final = value
        .get("is_final")
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
        || value
            .get("speech_final")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
    Some(Segment {
        speaker,
        text: text.to_string(),
        is_final,
    })
}
