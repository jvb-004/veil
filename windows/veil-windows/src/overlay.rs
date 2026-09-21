//! The overlay, and the one place where Windows is genuinely better than the
//! alternatives.
//!
//! `SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)` is enforced inside
//! DWM, before any capture path is handed a single pixel. Not BitBlt, not
//! PrintWindow, not DXGI Desktop Duplication, not Windows.Graphics.Capture,
//! and therefore not getDisplayMedia either, which is what Zoom, Teams, Meet
//! and OBS are all standing on. There is no per-application allowlist to keep
//! up with and no version cliff to test around, unlike macOS.
//!
//! The window styles matter as much as the flag:
//!   WS_EX_NOACTIVATE   never take focus. A focus steal dims the shared
//!                      window's title bar and eats the user's keystrokes.
//!   WS_EX_TOOLWINDOW   stay out of the taskbar and out of alt-tab.
//!   WS_EX_TRANSPARENT  clicks pass straight through to whatever is beneath.
//!   WS_EX_TOPMOST      above the call window.

#![cfg(windows)]

use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};

use windows_sys::core::PCWSTR;
use windows_sys::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, RECT, WPARAM};
use windows_sys::Win32::Graphics::Gdi::{
    BeginPaint, CreateFontW, CreateSolidBrush, DeleteObject, DrawTextW, EndPaint, FillRect,
    InvalidateRect, SelectObject, SetBkMode, SetTextColor, CLEARTYPE_QUALITY, DEFAULT_CHARSET,
    DT_LEFT, DT_NOPREFIX, DT_WORDBREAK, FF_DONTCARE, FW_NORMAL, PAINTSTRUCT, TRANSPARENT,
};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, GetWindowDisplayAffinity,
    PostQuitMessage, RegisterClassW, SetLayeredWindowAttributes, SetWindowDisplayAffinity,
    ShowWindow, TranslateMessage, LWA_ALPHA, MSG, SW_SHOWNOACTIVATE, WDA_EXCLUDEFROMCAPTURE,
    WDA_NONE, WM_DESTROY, WM_PAINT, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
};

/// What the window currently says. The message loop owns the window, so this
/// is how the rest of the program talks to it.
static TEXT: OnceLock<Mutex<String>> = OnceLock::new();
static WINDOW: OnceLock<usize> = OnceLock::new();

fn text_slot() -> &'static Mutex<String> {
    TEXT.get_or_init(|| Mutex::new(String::from("veil")))
}

pub fn set_text(text: &str) {
    if let Ok(mut slot) = text_slot().lock() {
        *slot = text.to_string();
    }
    if let Some(&hwnd) = WINDOW.get() {
        unsafe {
            InvalidateRect(hwnd as HWND, std::ptr::null(), 1);
        }
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Whether the exclusion actually took, read back from the OS rather than
/// assumed. The same call is how a determined proctor would detect us, which
/// is worth stating out loud rather than pretending otherwise.
pub fn protection_state(hwnd: HWND) -> &'static str {
    let mut affinity = 0u32;
    let ok = unsafe { GetWindowDisplayAffinity(hwnd, &mut affinity) };
    if ok == 0 {
        return "unknown";
    }
    match affinity {
        WDA_EXCLUDEFROMCAPTURE => "excluded from capture",
        WDA_NONE => "NOT protected",
        _ => "monitor-only (legacy)",
    }
}

pub fn run(width: i32, height: i32) -> anyhow::Result<()> {
    unsafe {
        let instance = GetModuleHandleW(std::ptr::null());
        let class_name = wide("veil_overlay");

        let class = WNDCLASSW {
            style: 0,
            lpfnWndProc: Some(window_proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: instance as _,
            hIcon: std::ptr::null_mut(),
            hCursor: std::ptr::null_mut(),
            hbrBackground: std::ptr::null_mut(),
            lpszMenuName: std::ptr::null(),
            lpszClassName: class_name.as_ptr(),
        };
        if RegisterClassW(&class) == 0 {
            anyhow::bail!("RegisterClassW failed");
        }

        let title = wide("veil");
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
            class_name.as_ptr(),
            title.as_ptr(),
            WS_POPUP,
            40,
            40,
            width,
            height,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            instance as _,
            std::ptr::null(),
        );
        if hwnd.is_null() {
            anyhow::bail!("CreateWindowExW failed");
        }

        // The whole reason Windows is the good platform for this.
        if SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE) == 0 {
            tracing::warn!(
                "SetWindowDisplayAffinity failed; needs Windows 10 build 19041 or later"
            );
        }
        tracing::info!("overlay protection: {}", protection_state(hwnd));

        SetLayeredWindowAttributes(hwnd, 0 as COLORREF, 235, LWA_ALPHA);
        ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        let _ = WINDOW.set(hwnd as usize);

        let mut message: MSG = std::mem::zeroed();
        while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    Ok(())
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match message {
        WM_PAINT => {
            let mut paint: PAINTSTRUCT = std::mem::zeroed();
            let hdc = BeginPaint(hwnd, &mut paint);

            let background = CreateSolidBrush(0x0014_1212 as COLORREF);
            FillRect(hdc, &paint.rcPaint, background);
            DeleteObject(background as *mut c_void);

            let face = wide("Segoe UI");
            let font = CreateFontW(
                -19,
                0,
                0,
                0,
                FW_NORMAL as i32,
                0,
                0,
                0,
                DEFAULT_CHARSET as u32,
                0,
                0,
                CLEARTYPE_QUALITY as u32,
                FF_DONTCARE as u32,
                face.as_ptr() as PCWSTR,
            );
            let previous = SelectObject(hdc, font as *mut c_void);
            SetBkMode(hdc, TRANSPARENT as i32);
            SetTextColor(hdc, 0x00F2_F2F2 as COLORREF);

            let body = text_slot().lock().map(|t| t.clone()).unwrap_or_default();
            let mut wide_body = wide(&body);
            let mut rect = RECT {
                left: paint.rcPaint.left + 14,
                top: paint.rcPaint.top + 12,
                right: paint.rcPaint.right - 14,
                bottom: paint.rcPaint.bottom - 12,
            };
            DrawTextW(
                hdc,
                wide_body.as_mut_ptr(),
                -1,
                &mut rect,
                DT_LEFT | DT_WORDBREAK | DT_NOPREFIX,
            );

            SelectObject(hdc, previous);
            DeleteObject(font as *mut c_void);
            EndPaint(hwnd, &paint);
            0
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            0
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}
