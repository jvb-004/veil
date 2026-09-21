# veil

Open-source, cross-platform meeting copilot. Listens to the far end of a call,
transcribes it, answers on a private overlay, and is honest about when that
overlay can and cannot be seen by the people you are sharing your screen with.

Working name. Rename freely.

## Status

Nothing is built yet except the experiment that decides the macOS design.

## Why the probe comes first

Every product in this category claims to be invisible during a screen share. On
Windows that claim is true and rests on one documented call,
`SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)`, enforced inside DWM
before any capture path sees a pixel.

On macOS the equivalent, `NSWindow.sharingType = .none`, is reported to have
stopped working against ScreenCaptureKit at **macOS 15.4**. Apple Developer
Technical Support, on the record: *"At this time there are no public APIs for
preventing screen capture."* Apple documents the constant as legacy, and on
macOS 26 setting it is reported to stop the window rendering at all.

Reports are not evidence. `macos/Probe` produces evidence.

## What the probe does

It puts a borderless magenta window on screen, then photographs the screen four
ways and counts magenta pixels. It runs the battery twice, once with
`sharingType = .readOnly` (the control, where the window must appear) and once
with `.none` (the claim under test).

| id | path | who uses it |
|----|------|-------------|
| A | ScreenCaptureKit `SCScreenshotManager` | Zoom, Teams, Chrome `getDisplayMedia`, QuickTime |
| B | `CGWindowListCreateImage` | legacy capture code |
| C | `/usr/sbin/screencapture` | Cmd-Shift-3 |
| D | per-window capture by window id | **the discriminator** |

D is the one that matters. Missing from A/B/C but present in D means genuine
capture exclusion. Missing from D as well means the window simply is not
rendering, which is not stealth, it is a broken window.

It also probes Core Audio process taps (`CATapDescription` +
`AudioHardwareCreateProcessTap`, macOS 14.4+), which is how far-end audio gets
captured on macOS without the loud Screen Recording permission.

## Running it

CI, on three OS versions at once:

```
gh workflow run "macOS capture probe"
```

Expected, if the reports are right: `FULLY_EXCLUDED` on macos-14,
`LEGACY_ONLY` on macos-15, `LEGACY_ONLY` or `WINDOW_STOPPED_RENDERING` on
macos-26. Any other result changes the product design.

A control run that sees nothing means the runner denied capture permission or
has no display, not that exclusion worked. The probe says so in its verdict.

## The design that follows

If macOS 15.4+ cannot exclude, then macOS and Linux are the same problem and the
same ladder applies. Ranked by how much it actually buys:

| | mechanism | works |
|---|---|---|
| S0 | **capture watchdog**: detect the share starting, hide within 500ms | everywhere, no permissions |
| S1 | second display, overlay lives on the unshared one | everywhere, absolute |
| S2 | phone or tablet over LAN | everywhere, absolute |
| S3 | earpiece and TTS, zero pixels | everywhere, absolute |
| S4 | `WDA_EXCLUDEFROMCAPTURE` | Windows 10 2004+ only |
| S5 | `sharingType = .none` | macOS below 15.4, legacy paths only |
| S6 | compositor patch | wlroots and KWin yes, Mutter needs a fork |

S0 is the interesting one and nobody ships it. On macOS, Zoom spawns a helper
process called `CptHost` when and only when a screen share starts, and Chrome
and Teams each raise a characteristic always-on-top sharing bar. Both are
observable through `CGWindowListCopyWindowInfo` and `NSWorkspace` with no TCC
permission at all. Your app knowing it is being filmed beats your app hoping it
is not.

## Honest scope

"Undetectable" is marketing. The accurate claim is "not present in the
screen-share pixel stream", which is a much smaller claim. Process enumeration,
TCC grants, virtual audio devices, outbound WebSockets, a fixed answer latency
and reading eye movement all remain. This repo will not pretend otherwise.

## Linux

Measured on Fedora 44, GNOME 50, Mutter 50, PipeWire 1.6.9, Wayland.

**Audio is the easy part.** The far end of the call is already on the default
sink's monitor source. `pw-record` hands it over as 16 kHz mono s16, which is
exactly what the ASR wants, with no driver, no virtual device, no permission
prompt and no resampler in this codebase to get subtly wrong. Verified on real
hardware: peak 4546 off the monitor, 95 KB off the microphone.

**Capture detection is exact, not heuristic.** On macOS the watchdog has to
sniff for Zoom's `CptHost` helper and for sharing toolbars. On Linux every
screen share goes through xdg-desktop-portal and the compositor publishes the
capture into the PipeWire graph, where we can simply read it.

The signature was measured rather than assumed, using a Mutter *virtual*
monitor session so no real screen content was ever captured:

```
media.class = "Stream/Output/Video"   node.name = "gnome-shell"
```

Not `Video/Source`. That class is cameras, and a webcam is exactly the false
positive that would otherwise blank your overlay every call. The compiled
watchdog was then run against a live session and flips `false -> true -> false`
on the transitions.

Because it is the graph and not a guess, it also reports **scope** (what is
being captured) and **consumers** (who is attached), so an overlay can decide
that a share of somebody else's window is none of its business.

**The overlay is a GNOME Shell extension.** Mutter has no layer-shell, so no
ordinary window can sit above a fullscreen Zoom without fighting the focus
stack. A shell widget is drawn by the compositor itself: always on top, never
focusable, absent from the window switcher and from the overview. The daemon
and the extension talk over D-Bus (`dev.veil.Daemon1`), which is also the seam
where a gtk4-layer-shell client drops in for wlroots compositors.

```
linux/gnome-extension/install.sh     # then log out, log in
gnome-extensions enable veil@veil.dev
DEEPGRAM_API_KEY=... ANTHROPIC_API_KEY=... linux/target/release/veil-daemon
```

### Known debt

`veil-core` duplicates the transcript, trigger and answering logic that
`macos/Veil` implements in Swift. The plan is a C ABI on this crate with the
Swift side reduced to a UI shim, rather than two copies of the trigger
heuristics drifting apart. Until that lands, changes to one need mirroring in
the other.
