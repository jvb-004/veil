//! S0 for Windows, in two independent halves.
//!
//! Half one is the same heuristic the macOS target uses: look for the helper
//! process and the sharing toolbars that conferencing apps raise when, and
//! only when, a share begins. On Windows this is easier than on macOS, because
//! window titles are readable without any permission at all.
//!
//! Half two has no equivalent on the other two platforms and is the reason
//! this file is worth writing. It does not trust WDA_EXCLUDEFROMCAPTURE. It
//! captures the overlay's own rectangle off the screen, exactly the way Zoom
//! would, and checks whether the overlay is in it. If our own window ever
//! shows up in our own capture, the exclusion has stopped working and we hide
//! within a second.
//!
//! That matters because the failure mode this whole project is built around is
//! silent. macOS 14 and 15 keep reporting the flag as set while leaking the
//! window into a live stream the moment the capturer touches its filter. A
//! flag you can read back tells you what you asked for. Only a capture tells
//! you what actually happened.

#![cfg(windows)]

use std::ffi::c_void;
use std::sync::mpsc;
use std::time::Duration;

use windows_sys::core::BOOL;
use windows_sys::Win32::Foundation::{HWND, LPARAM, RECT};
use windows_sys::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
    ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, SRCCOPY,
};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetClassNameW, GetWindowRect, GetWindowTextW, IsWindowVisible,
};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ShareState {
    /// Somebody looks like they are sharing the screen.
    pub capture_suspected: bool,
    pub reasons: Vec<String>,
    /// True when we captured our own rectangle and did NOT find ourselves,
    /// which is the exclusion working. False means it is broken, and that is
    /// the alarm this file exists to raise.
    pub exclusion_holding: bool,
    pub exclusion_checked: bool,
}

/// Processes that exist only while a share is running.
const SHARE_HELPERS: &[&str] = &["CptHost.exe", "ZoomSharingHost.exe"];

/// Titles the conferencing apps put on their sharing control bars. Matched
/// case-insensitively against every visible top-level window.
const SHARING_TITLES: &[&str] = &[
    "sharing your screen",
    "you are screen sharing",
    "stop sharing",
    "stop share",
    "is being shared",
];

pub fn spawn(overlay: usize) -> mpsc::Receiver<ShareState> {
    let (tx, rx) = mpsc::channel();
    std::thread::Builder::new()
        .name("veil-watchdog".into())
        .spawn(move || {
            let mut previous = ShareState::default();
            loop {
                let state = poll(overlay as HWND);
                if state != previous {
                    previous = state.clone();
                    if tx.send(state).is_err() {
                        return;
                    }
                }
                std::thread::sleep(Duration::from_millis(700));
            }
        })
        .expect("spawn watchdog thread");
    rx
}

fn poll(overlay: HWND) -> ShareState {
    let mut reasons = Vec::new();

    for name in running_processes() {
        if SHARE_HELPERS.iter().any(|h| h.eq_ignore_ascii_case(&name)) {
            reasons.push(format!("share helper process running: {name}"));
        }
    }
    reasons.extend(sharing_bars());

    let (checked, holding) = unsafe { exclusion_holds(overlay) };
    if checked && !holding {
        reasons.push("SELF-TEST FAILED: the overlay appeared in our own screen capture".into());
    }

    ShareState {
        capture_suspected: !reasons.is_empty(),
        reasons,
        exclusion_holding: holding,
        exclusion_checked: checked,
    }
}

fn running_processes() -> Vec<String> {
    let mut names = Vec::new();
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot.is_null() {
            return names;
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snapshot, &mut entry) != 0 {
            loop {
                names.push(from_wide(&entry.szExeFile));
                if Process32NextW(snapshot, &mut entry) == 0 {
                    break;
                }
            }
        }
    }
    names
}

fn sharing_bars() -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    unsafe {
        EnumWindows(Some(enum_proc), &mut found as *mut Vec<String> as LPARAM);
    }
    found
}

unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    if IsWindowVisible(hwnd) == 0 {
        return 1;
    }
    let mut title = [0u16; 256];
    let len = GetWindowTextW(hwnd, title.as_mut_ptr(), title.len() as i32);
    if len <= 0 {
        return 1;
    }
    let text = String::from_utf16_lossy(&title[..len as usize]).to_lowercase();
    if let Some(hit) = SHARING_TITLES.iter().find(|needle| text.contains(**needle)) {
        let mut class = [0u16; 128];
        let class_len = GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32);
        let class_name = if class_len > 0 {
            String::from_utf16_lossy(&class[..class_len as usize])
        } else {
            String::new()
        };
        let list = &mut *(lparam as *mut Vec<String>);
        list.push(format!("sharing bar visible: \"{hit}\" ({class_name})"));
    }
    1
}

fn from_wide(buffer: &[u16]) -> String {
    let end = buffer.iter().position(|&c| c == 0).unwrap_or(buffer.len());
    String::from_utf16_lossy(&buffer[..end])
}

/// Capture the overlay's own rectangle off the screen and look for the marker
/// it paints. Finding it means a screen capture can see the overlay, which
/// means the exclusion is not working, whatever the flag claims.
///
/// Returns (checked, holding). `checked` is false when there is nothing
/// meaningful to test, for instance when the window is not on screen.
unsafe fn exclusion_holds(overlay: HWND) -> (bool, bool) {
    if overlay.is_null() || IsWindowVisible(overlay) == 0 {
        return (false, true);
    }
    let mut rect: RECT = std::mem::zeroed();
    if GetWindowRect(overlay, &mut rect) == 0 {
        return (false, true);
    }
    let width = rect.right - rect.left;
    let height = rect.bottom - rect.top;
    if width <= 0 || height <= 0 {
        return (false, true);
    }

    let screen = GetDC(std::ptr::null_mut());
    let memory_dc = CreateCompatibleDC(screen);
    let bitmap = CreateCompatibleBitmap(screen, width, height);
    let previous = SelectObject(memory_dc, bitmap as *mut c_void);

    // Exactly what a screen sharer does, aimed at exactly where we are.
    BitBlt(
        memory_dc, 0, 0, width, height, screen, rect.left, rect.top, SRCCOPY,
    );

    let mut info: BITMAPINFO = std::mem::zeroed();
    info.bmiHeader = BITMAPINFOHEADER {
        biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
        biWidth: width,
        biHeight: -height,
        biPlanes: 1,
        biBitCount: 32,
        biCompression: BI_RGB,
        biSizeImage: 0,
        biXPelsPerMeter: 0,
        biYPelsPerMeter: 0,
        biClrUsed: 0,
        biClrImportant: 0,
    };
    let mut pixels = vec![0u8; (width * height * 4) as usize];
    GetDIBits(
        memory_dc,
        bitmap,
        0,
        height as u32,
        pixels.as_mut_ptr() as *mut c_void,
        &mut info,
        DIB_RGB_COLORS,
    );

    SelectObject(memory_dc, previous);
    DeleteObject(bitmap as *mut c_void);
    DeleteDC(memory_dc);
    ReleaseDC(std::ptr::null_mut(), screen);

    // The marker is drawn at full saturation but the window is layered, so the
    // captured pixel would be our colour blended over whatever is behind it.
    // Match with tolerance rather than exactly.
    let marker_pixels = pixels
        .chunks_exact(4)
        .filter(|p| p[2] > 190 && p[1] < 90 && p[0] > 190)
        .count();

    // A handful of stray pixels could be anything. The marker is far larger.
    (true, marker_pixels < 24)
}
