//! The daemon's face to the world.
//!
//! The overlay is a separate process because on GNOME that is the only way to
//! get a window that is genuinely always on top, never steals focus and never
//! appears in the window switcher: a GNOME Shell extension draws it inside the
//! compositor itself. The extension listens here.
//!
//! On wlroots compositors a gtk4-layer-shell client can subscribe to exactly
//! the same signals, which is why this seam exists at all.

use zbus::interface;
use zbus::object_server::SignalEmitter;

pub struct Daemon {
    pub version: String,
}

#[interface(name = "dev.veil.Daemon1")]
impl Daemon {
    /// Liveness, so the extension can tell "daemon not running" from "quiet".
    fn ping(&self) -> String {
        self.version.clone()
    }

    #[zbus(signal)]
    pub async fn answer(
        emitter: &SignalEmitter<'_>,
        question: &str,
        body: &str,
        speculative: bool,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    pub async fn status(emitter: &SignalEmitter<'_>, text: &str) -> zbus::Result<()>;

    /// sharing plus the scope strings, so the overlay can decide whether this
    /// particular share is any of its business.
    #[zbus(signal)]
    pub async fn sharing(
        emitter: &SignalEmitter<'_>,
        sharing: bool,
        scope: Vec<String>,
    ) -> zbus::Result<()>;
}
