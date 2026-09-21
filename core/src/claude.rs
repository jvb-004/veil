//! Streaming answers from the Messages API.
//!
//! Three deliberate settings, all of them about the fact that the output gets
//! read ALOUD, in real time, by a person maintaining eye contact:
//!
//! - thinking stays adaptive with effort low. Thinking on avoids the documented
//!   failure modes of disabling it; low effort keeps first-token latency down.
//! - max_tokens is 700, far under the usual streaming default. Anything longer
//!   is not merely wasted, it is unusable when spoken.
//! - server-side fallbacks are on, so a refusal reroutes instead of leaving the
//!   overlay empty in the middle of a sentence.

use anyhow::{bail, Context, Result};
use futures_util::StreamExt;
use tokio::sync::mpsc;

pub struct Claude {
    client: reqwest::Client,
    api_key: String,
    model: String,
    persona: String,
    user_context: String,
}

impl Claude {
    pub fn new(api_key: String, model: String, persona: String, user_context: String) -> Self {
        Self {
            client: reqwest::Client::new(),
            api_key,
            model,
            persona,
            user_context,
        }
    }

    fn system_prompt(&self) -> String {
        let background = if self.user_context.is_empty() {
            String::new()
        } else {
            format!(
                "\n\nBackground on the user and the subject:\n{}",
                self.user_context
            )
        };
        format!(
            "{persona}\n\n\
             You produce lines the user will read ALOUD, immediately, while the other person \
             is watching their face. Everything follows from that:\n\n\
             - First line is the answer itself, in at most 12 words. No preamble, no \
             \"Great question\", no restating what was asked.\n\
             - Then at most three short supporting lines, each a separate idea the user can \
             pick up or skip.\n\
             - Spoken register. Contractions, plain words, no markdown, no bullet syntax the \
             user would have to translate out loud.\n\
             - If it is a number, a name or a date, lead with it.\n\
             - If you do not know, say so in one short line and offer the nearest thing you do \
             know. A confident wrong answer spoken aloud is the worst possible outcome.{background}",
            persona = self.persona,
        )
    }

    /// Streams tokens into the returned receiver. Dropping the task cancels it,
    /// which is how a speculative answer gets superseded.
    pub fn answer(&self, question: String, transcript: String) -> mpsc::Receiver<String> {
        let (tx, rx) = mpsc::channel(256);
        let client = self.client.clone();
        let api_key = self.api_key.clone();
        let model = self.model.clone();
        let system = self.system_prompt();

        tokio::spawn(async move {
            if let Err(e) = stream(client, api_key, model, system, question, transcript, &tx).await
            {
                let _ = tx.send(format!("\n[error: {e}]")).await;
            }
        });

        rx
    }
}

async fn stream(
    client: reqwest::Client,
    api_key: String,
    model: String,
    system: String,
    question: String,
    transcript: String,
    tx: &mpsc::Sender<String>,
) -> Result<()> {
    let user_message = format!(
        "Conversation so far (THEM is the other person, YOU is the user):\n{transcript}\n\n\
         Answer this, which THEM just asked:\n{question}"
    );

    let body = serde_json::json!({
        "model": model,
        "max_tokens": 700,
        "stream": true,
        "system": system,
        "thinking": { "type": "adaptive" },
        "output_config": { "effort": "low" },
        "fallbacks": "default",
        "messages": [{ "role": "user", "content": user_message }],
    });

    let response = client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("anthropic-beta", "server-side-fallback-2026-07-01")
        .header("content-type", "application/json")
        .json(&body)
        .send()
        .await
        .context("messages request")?;

    if !response.status().is_success() {
        let status = response.status();
        let detail = response.text().await.unwrap_or_default();
        bail!(
            "HTTP {status}: {}",
            detail.chars().take(400).collect::<String>()
        );
    }

    let mut stream = response.bytes_stream();
    let mut buffer = String::new();

    while let Some(chunk) = stream.next().await {
        buffer.push_str(&String::from_utf8_lossy(&chunk.context("stream chunk")?));
        while let Some(newline) = buffer.find('\n') {
            let line: String = buffer.drain(..=newline).collect();
            let line = line.trim_end();
            let Some(payload) = line.strip_prefix("data: ") else {
                continue;
            };
            let Ok(event) = serde_json::from_str::<serde_json::Value>(payload) else {
                continue;
            };

            match event.get("type").and_then(|v| v.as_str()) {
                Some("content_block_delta") => {
                    if let Some(text) = event
                        .get("delta")
                        .filter(|d| d.get("type").and_then(|t| t.as_str()) == Some("text_delta"))
                        .and_then(|d| d.get("text"))
                        .and_then(|t| t.as_str())
                    {
                        if tx.send(text.to_string()).await.is_err() {
                            return Ok(()); // superseded, stop paying for it
                        }
                    }
                }
                Some("message_delta") => {
                    // stop_details is populated only on a refusal, so guard first.
                    if event
                        .get("delta")
                        .and_then(|d| d.get("stop_reason"))
                        .and_then(|s| s.as_str())
                        == Some("refusal")
                    {
                        let category = event
                            .get("stop_details")
                            .and_then(|d| d.get("category"))
                            .and_then(|c| c.as_str())
                            .unwrap_or("unspecified");
                        let _ = tx.send(format!("\n[declined: {category}]")).await;
                    }
                }
                Some("error") => {
                    let message = event
                        .get("error")
                        .and_then(|e| e.get("message"))
                        .and_then(|m| m.as_str())
                        .unwrap_or("unknown");
                    bail!("{message}");
                }
                _ => {}
            }
        }
    }
    Ok(())
}
