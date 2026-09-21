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
