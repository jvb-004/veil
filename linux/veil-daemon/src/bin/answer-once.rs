//! Proves the answering half live, with only an Anthropic key.
//!
//!   answer-once "how much is a litre of milk"
//!
//! Skips audio and ASR entirely and drives Claude the way the daemon does:
//! same system prompt, same streaming, same settings. If this prints tokens,
//! the model path works and anything still broken is upstream of it.

use std::io::Write;

use veil_core::{Claude, Config};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let question: String = std::env::args().skip(1).collect::<Vec<_>>().join(" ");
    if question.is_empty() {
        eprintln!("usage: answer-once <question>");
        std::process::exit(2);
    }

    let config = Config::load();
    let Some(key) = config.anthropic_api_key.clone() else {
        anyhow::bail!("ANTHROPIC_API_KEY is not set and no key in ~/.config/veil/config.json");
    };

    let claude = Claude::new(
        key,
        config.model.clone(),
        config.persona.clone(),
        config.user_context(),
    );

    eprintln!("model: {}", config.model);
    eprintln!("question: {question}");
    eprintln!("--- answer ---");

    let started = std::time::Instant::now();
    let mut first_token: Option<std::time::Duration> = None;
    let mut rx = claude.answer(question, "THEM: (start of conversation)".into());

    while let Some(token) = rx.recv().await {
        if first_token.is_none() {
            first_token = Some(started.elapsed());
        }
        print!("{token}");
        std::io::stdout().flush().ok();
    }

    println!();
    eprintln!("--- done ---");
    if let Some(ttft) = first_token {
        eprintln!("first token: {} ms", ttft.as_millis());
    } else {
        eprintln!("no tokens received");
    }
    eprintln!("total: {} ms", started.elapsed().as_millis());
    Ok(())
}
