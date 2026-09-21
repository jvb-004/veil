//! S0: know when you are being filmed.
//!
//! On macOS this has to be a heuristic, sniffing for helper processes and
//! sharing toolbars. On Linux it is exact. Every screen share on Wayland goes
//! through xdg-desktop-portal, the compositor publishes the capture as a
//! PipeWire node, and that node is right there in the graph with a description
//! saying what is being shared.
//!
//! So we do not merely detect that a share is running. We detect its SCOPE,
//! which is the part that matters: if they are sharing one window and it is not
//! ours, the overlay has no reason to hide at all.

use serde::Deserialize;
use std::time::Duration;
use tokio::sync::watch;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ShareState {
    pub sharing: bool,
    /// What the compositor says is being captured, e.g. a monitor or a window.
    pub scope: Vec<String>,
    /// Who is consuming it, when anyone is attached yet.
    pub consumers: Vec<String>,
}

#[derive(Deserialize)]
struct PwObject {
    #[serde(default)]
    info: Option<PwInfo>,
}

#[derive(Deserialize)]
struct PwInfo {
    #[serde(default)]
    props: Option<serde_json::Map<String, serde_json::Value>>,
}

pub fn spawn() -> watch::Receiver<ShareState> {
    let (tx, rx) = watch::channel(ShareState::default());
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_millis(700));
        loop {
            ticker.tick().await;
            let state = poll().await.unwrap_or_default();
            if *tx.borrow() != state {
                tracing::info!("share state changed: {state:?}");
                let _ = tx.send(state);
            }
        }
    });
    rx
}

async fn poll() -> Option<ShareState> {
    let output = tokio::process::Command::new("pw-dump")
        .output()
        .await
        .ok()?;
    let objects: Vec<PwObject> = serde_json::from_slice(&output.stdout).ok()?;
    Some(evaluate(
        objects
            .into_iter()
            .filter_map(|o| o.info.and_then(|i| i.props)),
    ))
}

/// Measured, not assumed. A live screencast on GNOME 50 / Mutter 50 shows up as
/// a node with media.class "Stream/Output/Video" whose producer is the
/// compositor itself, e.g. node.name "gnome-shell". It is NOT a Video/Source;
/// that class is cameras, which is exactly the false positive to avoid.
///
/// KWin, wlroots portals and Hyprland publish the same class under their own
/// producer names, so the class is the signal and the name is the detail.
fn evaluate<I>(props_iter: I) -> ShareState
where
    I: Iterator<Item = serde_json::Map<String, serde_json::Value>>,
{
    let mut scope = Vec::new();
    let mut consumers = Vec::new();

    for props in props_iter {
        let class = props
            .get("media.class")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let name = props
            .get("node.name")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        match class {
            "Stream/Output/Video" => {
                let description = props
                    .get("node.description")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty())
                    .unwrap_or(name);
                scope.push(description.to_string());
            }
            // Who is watching. Tells the overlay whether this share is its problem.
            "Stream/Input/Video" => {
                let who = props
                    .get("application.name")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty())
                    .unwrap_or(name);
                consumers.push(who.to_string());
            }
            _ => {}
        }
    }

    ShareState {
        sharing: !scope.is_empty(),
        scope,
        consumers,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn props(pairs: &[(&str, &str)]) -> serde_json::Map<String, serde_json::Value> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), serde_json::Value::String(v.to_string())))
            .collect()
    }

    #[test]
    fn a_webcam_is_not_a_screen_share() {
        // Captured from a real idle graph: the built-in camera.
        let state = evaluate(
            vec![props(&[
                ("media.class", "Video/Source"),
                ("node.name", "v4l2_input.pci-0000_00_14.0-usb-0_6_1.0"),
            ])]
            .into_iter(),
        );
        assert!(!state.sharing);
    }

    #[test]
    fn a_live_screencast_is_detected() {
        // Captured from a real Mutter screencast session on GNOME 50.
        let state = evaluate(
            vec![props(&[
                ("media.class", "Stream/Output/Video"),
                ("node.name", "gnome-shell"),
            ])]
            .into_iter(),
        );
        assert!(state.sharing);
        assert_eq!(state.scope, vec!["gnome-shell".to_string()]);
    }

    #[test]
    fn the_consumer_is_reported_so_the_overlay_can_judge() {
        let state = evaluate(
            vec![
                props(&[
                    ("media.class", "Stream/Output/Video"),
                    ("node.name", "gnome-shell"),
                ]),
                props(&[
                    ("media.class", "Stream/Input/Video"),
                    ("application.name", "Zoom"),
                ]),
            ]
            .into_iter(),
        );
        assert!(state.sharing);
        assert_eq!(state.consumers, vec!["Zoom".to_string()]);
    }
}
