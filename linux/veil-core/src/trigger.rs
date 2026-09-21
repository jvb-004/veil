//! When to answer. This, not the overlay, is the product.
//!
//! Fires speculatively on a stable interim transcript so the first token lands
//! before the sentence has finished, then supersedes itself if the final
//! transcript turns out to say something materially different. Being
//! occasionally wrong quickly beats being reliably right too late.

use std::collections::HashSet;
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct Decision {
    pub text: String,
    pub speculative: bool,
}

pub struct Trigger {
    last_interim: String,
    last_interim_at: Instant,
    last_fired_text: String,
    last_fired_at: Instant,
    speculation_outstanding: bool,
    stability: Duration,
    debounce: Duration,
    min_words: usize,
}

impl Default for Trigger {
    fn default() -> Self {
        let past = Instant::now() - Duration::from_secs(3600);
        Self {
            last_interim: String::new(),
            last_interim_at: past,
            last_fired_text: String::new(),
            last_fired_at: past,
            speculation_outstanding: false,
            stability: Duration::from_millis(250),
            debounce: Duration::from_millis(1200),
            min_words: 4,
        }
    }
}

impl Trigger {
    pub fn consider_interim(&mut self, text: &str) -> Option<Decision> {
        let text = text.trim();
        if text != self.last_interim {
            self.last_interim = text.to_string();
            self.last_interim_at = Instant::now();
            return None;
        }
        // Held still long enough and reads like a question? Go early.
        if self.speculation_outstanding
            || self.last_interim_at.elapsed() < self.stability
            || self.last_fired_at.elapsed() < self.debounce
            || word_count(text) < self.min_words
            || !looks_like_question(text)
        {
            return None;
        }
        self.speculation_outstanding = true;
        Some(self.fire(text, true))
    }

    pub fn consider_final(&mut self, text: &str) -> Option<Decision> {
        let text = text.trim();
        self.last_interim.clear();
        self.speculation_outstanding = false;
        if word_count(text) < 2 {
            return None;
        }
        // If the speculation already covered it, do not pay for it twice.
        if !self.last_fired_text.is_empty() && similarity(text, &self.last_fired_text) > 0.85 {
            return None;
        }
        if !looks_like_question(text) && !is_imperative(text) {
            return None;
        }
        Some(self.fire(text, false))
    }

    /// Manual override. Sometimes you just want an answer.
    pub fn fire_manually(&mut self, text: &str) -> Decision {
        self.fire(text.trim(), false)
    }

    fn fire(&mut self, text: &str, speculative: bool) -> Decision {
        self.last_fired_text = text.to_string();
        self.last_fired_at = Instant::now();
        Decision {
            text: text.to_string(),
            speculative,
        }
    }
}

fn word_count(s: &str) -> usize {
    s.split_whitespace().count()
}

const INTERROGATIVES: &[&str] = &[
    "what", "why", "how", "when", "where", "who", "which", "whose", "can", "could", "would",
    "should", "do", "does", "did", "is", "are", "was", "were", "will", "have", "has", "am", "may",
    "might",
];

fn looks_like_question(text: &str) -> bool {
    if text.ends_with('?') {
        return true;
    }
    let first: String = text
        .chars()
        .skip_while(|c| !c.is_alphabetic())
        .take_while(|c| c.is_alphabetic())
        .flat_map(|c| c.to_lowercase())
        .collect();
    INTERROGATIVES.contains(&first.as_str())
}

const IMPERATIVES: &[&str] = &[
    "tell me",
    "walk me through",
    "explain",
    "describe",
    "give me",
    "talk about",
    "let's talk",
    "go over",
];

fn is_imperative(text: &str) -> bool {
    let lower = text.to_lowercase();
    IMPERATIVES.iter().any(|p| lower.contains(p))
}

/// Cheap token overlap. Enough to answer "is this the same question".
fn similarity(a: &str, b: &str) -> f64 {
    let sa: HashSet<String> = a
        .to_lowercase()
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let sb: HashSet<String> = b
        .to_lowercase()
        .split_whitespace()
        .map(str::to_string)
        .collect();
    if sa.is_empty() || sb.is_empty() {
        return 0.0;
    }
    sa.intersection(&sb).count() as f64 / sa.len().max(sb.len()) as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_questions_and_imperatives() {
        assert!(looks_like_question("how much is a litre of milk"));
        assert!(looks_like_question("that costs what?"));
        assert!(!looks_like_question("the milk is in the fridge"));
        assert!(is_imperative("walk me through your approach"));
    }

    #[test]
    fn final_does_not_refire_the_same_question() {
        let mut t = Trigger::default();
        let d = t.fire_manually("how much is a litre of milk");
        assert!(!d.speculative);
        assert!(t.consider_final("how much is a litre of milk").is_none());
    }

    #[test]
    fn final_refires_when_the_question_actually_changed() {
        let mut t = Trigger::default();
        t.fire_manually("how much is a litre of milk");
        assert!(t
            .consider_final("what is the capital of Azerbaijan?")
            .is_some());
    }

    #[test]
    fn short_noise_is_ignored() {
        let mut t = Trigger::default();
        assert!(t.consider_final("uh").is_none());
    }
}
