//! Bring your own keys. Environment first, then ~/.config/veil/config.json.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub anthropic_api_key: Option<String>,
    pub deepgram_api_key: Option<String>,
    pub model: String,
    pub stt_model: String,
    pub language: String,
    /// Your CV, the product docs, the brief. Read once at launch.
    pub context_file: Option<String>,
    pub persona: String,
    /// PipeWire target for the other side of the call. Empty means the default
    /// sink's monitor, which is what you want almost always.
    pub far_target: Option<String>,
    pub near_target: Option<String>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            anthropic_api_key: None,
            deepgram_api_key: None,
            model: "claude-opus-5".into(),
            stt_model: "nova-3".into(),
            language: "en".into(),
            context_file: None,
            persona: "You are assisting the user during a live conversation.".into(),
            far_target: None,
            near_target: None,
        }
    }
}

impl Config {
    pub fn load() -> Self {
        let mut config = dirs_config_path()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|s| serde_json::from_str::<Config>(&s).ok())
            .unwrap_or_default();

        if let Ok(k) = std::env::var("ANTHROPIC_API_KEY") {
            if !k.is_empty() {
                config.anthropic_api_key = Some(k);
            }
        }
        if let Ok(k) = std::env::var("DEEPGRAM_API_KEY") {
            if !k.is_empty() {
                config.deepgram_api_key = Some(k);
            }
        }
        if let Ok(m) = std::env::var("VEIL_MODEL") {
            if !m.is_empty() {
                config.model = m;
            }
        }
        config
    }

    pub fn user_context(&self) -> String {
        self.context_file
            .as_ref()
            .and_then(|p| std::fs::read_to_string(shellexpand(p)).ok())
            .map(|s| s.chars().take(20_000).collect())
            .unwrap_or_default()
    }
}

fn shellexpand(path: &str) -> String {
    match path.strip_prefix("~/") {
        Some(rest) => std::env::var("HOME")
            .map(|h| format!("{h}/{rest}"))
            .unwrap_or_else(|_| path.to_string()),
        None => path.to_string(),
    }
}

fn dirs_config_path() -> Option<std::path::PathBuf> {
    let home = std::env::var("HOME").ok()?;
    Some(std::path::PathBuf::from(home).join(".config/veil/config.json"))
}
