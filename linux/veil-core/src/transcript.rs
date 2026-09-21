//! Rolling transcript, tagged by source.
//!
//! Attribution is by capture device, not by a diarisation model. Far end came
//! off the sink monitor, near end came off the microphone. No guessing.

use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Speaker {
    FarEnd,
    NearEnd,
}

impl Speaker {
    pub fn label(&self) -> &'static str {
        match self {
            Speaker::FarEnd => "THEM",
            Speaker::NearEnd => "YOU",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Segment {
    pub speaker: Speaker,
    pub text: String,
    pub is_final: bool,
}

#[derive(Default)]
pub struct Transcript {
    lines: Vec<(Speaker, String)>,
    interim: HashMap<Speaker, String>,
}

impl Transcript {
    const MAX_LINES: usize = 60;

    pub fn apply(&mut self, segment: &Segment) {
        if segment.is_final {
            self.interim.remove(&segment.speaker);
            let text = segment.text.trim();
            if text.is_empty() {
                return;
            }
            self.lines.push((segment.speaker, text.to_string()));
            if self.lines.len() > Self::MAX_LINES {
                let excess = self.lines.len() - Self::MAX_LINES;
                self.lines.drain(0..excess);
            }
        } else {
            self.interim.insert(segment.speaker, segment.text.clone());
        }
    }

    /// What the model sees. Recent turns only: three minutes of small talk
    /// before the question is noise, and noise costs latency.
    pub fn context(&self, last_turns: usize) -> String {
        let start = self.lines.len().saturating_sub(last_turns);
        self.lines[start..]
            .iter()
            .map(|(speaker, text)| format!("{}: {}", speaker.label(), text))
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn last_far_end(&self) -> Option<&str> {
        self.lines
            .iter()
            .rev()
            .find(|(s, _)| *s == Speaker::FarEnd)
            .map(|(_, t)| t.as_str())
    }
}
