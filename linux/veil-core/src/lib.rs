//! Platform-independent half of veil: transcript, trigger, ASR and answering.
//!
//! Known debt, stated plainly: the macOS target reimplements this in Swift.
//! The plan is for this crate to grow a C ABI and for the Swift side to become
//! a thin UI shim over it, rather than two copies of the trigger heuristics
//! drifting apart. Until then, changes here need mirroring in macos/Veil.

pub mod claude;
pub mod config;
pub mod deepgram;
pub mod transcript;
pub mod trigger;

pub use claude::Claude;
pub use config::Config;
pub use deepgram::Deepgram;
pub use transcript::{Segment, Speaker, Transcript};
pub use trigger::{Decision, Trigger};
