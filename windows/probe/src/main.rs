//! veil Windows capture-exclusion probe.
//!
//! Same discipline as the macOS probe, and for the same reason: the claim that
//! a window can be invisible to a screen share is repeated everywhere and
//! measured almost nowhere. On macOS that scepticism paid: the flag turned out
//! to work where the internet said it was dead, and to fail open on a live
//! stream where the internet said it was fine.
//!
//! Method: a magenta window with WDA_EXCLUDEFROMCAPTURE and a cyan control
//! window without it, both on screen at once. Photograph the screen, count
//! both colours. Cyan present and magenta absent in the SAME frame means the
//! capture worked and only the protected window was removed, which is the
//! only form of this result worth believing.

#[cfg(not(windows))]
fn main() {
    eprintln!("this probe only runs on Windows");
}

#[cfg(windows)]
fn main() {
    windows_probe::run();
}

#[cfg(windows)]
mod windows_probe {
    use std::ffi::c_void;

    use windows_sys::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, WPARAM};
    use windows_sys::Win32::Graphics::Gdi::{
        BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, CreateSolidBrush, DeleteDC,
        DeleteObject, GetDC, GetDIBits, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER,
        BI_RGB, DIB_RGB_COLORS, HBITMAP, HDC, SRCCOPY,
    };
    use windows_sys::Win32::Storage::Xps::PrintWindow;
    use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DispatchMessageW, GetDesktopWindow, GetSystemMetrics,
        GetWindowDisplayAffinity, PeekMessageW, PrintWindow, RegisterClassW,
        SetWindowDisplayAffinity, ShowWindow, TranslateMessage, MSG, PM_REMOVE,
        PW_RENDERFULLCONTENT, SM_CXSCREEN, SM_CYSCREEN, SW_SHOWNOACTIVATE, WDA_EXCLUDEFROMCAPTURE,
        WDA_MONITOR, WDA_NONE, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
        WS_EX_TOPMOST, WS_POPUP,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{SetLayeredWindowAttributes, LWA_ALPHA};

    const WIDTH: i32 = 420;
    const HEIGHT: i32 = 300;
    const MAGENTA: u32 = 0x00FF_00FF;
    const CYAN: u32 = 0x0000_FFFF;

    #[derive(Default, Debug)]
    struct Counts {
        magenta: i64,
        cyan: i64,
    }

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    unsafe extern "system" fn proc(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT {
        DefWindowProcW(h, m, w, l)
    }

    unsafe fn make_window(class: &str, colour: u32, x: i32, protect: bool) -> HWND {
        let instance = GetModuleHandleW(std::ptr::null());
        let class_name = wide(class);
        // A solid class background is the simplest way to guarantee the window
        // is actually painting the marker colour, with no WM_PAINT of our own.
        let brush = CreateSolidBrush(swap_rgb(colour) as COLORREF);
        let wc = WNDCLASSW {
            style: 0,
            lpfnWndProc: Some(proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: instance as _,
            hIcon: std::ptr::null_mut(),
            hCursor: std::ptr::null_mut(),
            hbrBackground: brush,
            lpszMenuName: std::ptr::null(),
            lpszClassName: class_name.as_ptr(),
        };
        RegisterClassW(&wc);
        let title = wide(class);
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            class_name.as_ptr(),
            title.as_ptr(),
            WS_POPUP,
            x,
            80,
            WIDTH,
            HEIGHT,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            instance as _,
            std::ptr::null(),
        );
        if !hwnd.is_null() {
            SetLayeredWindowAttributes(hwnd, 0 as COLORREF, 255, LWA_ALPHA);
            if protect {
                SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE);
            }
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        }
        hwnd
    }

    /// COLORREF is 0x00BBGGRR while our constants read as 0x00RRGGBB.
    fn swap_rgb(rgb: u32) -> u32 {
        let r = (rgb >> 16) & 0xFF;
        let g = (rgb >> 8) & 0xFF;
        let b = rgb & 0xFF;
        (b << 16) | (g << 8) | r
    }

    unsafe fn pump(millis: u64) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(millis);
        let mut message: MSG = std::mem::zeroed();
        while std::time::Instant::now() < deadline {
            while PeekMessageW(&mut message, std::ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    unsafe fn count_from_dc(source: HDC, width: i32, height: i32) -> Counts {
        let memory_dc = CreateCompatibleDC(source);
        let bitmap: HBITMAP = CreateCompatibleBitmap(source, width, height);
        let previous = SelectObject(memory_dc, bitmap as *mut c_void);

        BitBlt(memory_dc, 0, 0, width, height, source, 0, 0, SRCCOPY);

        let mut info: BITMAPINFO = std::mem::zeroed();
        info.bmiHeader = BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width,
            biHeight: -height, // top-down
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

        let mut counts = Counts::default();
        for chunk in pixels.chunks_exact(4) {
            let (b, g, r) = (chunk[0], chunk[1], chunk[2]);
            if r > 220 && g < 50 && b > 220 {
                counts.magenta += 1;
            } else if r < 50 && g > 220 && b > 220 {
                counts.cyan += 1;
            }
        }
        counts
    }

    unsafe fn affinity_of(hwnd: HWND) -> &'static str {
        let mut value = 0u32;
        if GetWindowDisplayAffinity(hwnd, &mut value) == 0 {
            return "query failed";
        }
        match value {
            WDA_EXCLUDEFROMCAPTURE => "WDA_EXCLUDEFROMCAPTURE",
            WDA_MONITOR => "WDA_MONITOR",
            WDA_NONE => "WDA_NONE",
            _ => "unknown",
        }
    }

    pub fn run() {
        unsafe {
            let width = GetSystemMetrics(SM_CXSCREEN);
            let height = GetSystemMetrics(SM_CYSCREEN);

            let protected = make_window("veil_probe_protected", MAGENTA, 80, true);
            let control = make_window("veil_probe_control", CYAN, 540, false);
            pump(1200);

            // A: the classic path. GDI BitBlt straight off the screen DC.
            let screen = GetDC(std::ptr::null_mut());
            let bitblt = count_from_dc(screen, width, height);
            ReleaseDC(std::ptr::null_mut(), screen);

            // B: PrintWindow on the desktop with RENDERFULLCONTENT, which is the
            // path that defeats naive "hide the window" tricks.
            let desktop = GetDesktopWindow();
            let desktop_dc = GetDC(desktop);
            let memory_dc = CreateCompatibleDC(desktop_dc);
            let bitmap = CreateCompatibleBitmap(desktop_dc, width, height);
            let previous = SelectObject(memory_dc, bitmap as *mut c_void);
            PrintWindow(desktop, memory_dc, PW_RENDERFULLCONTENT);
            let printwindow = count_from_dc(memory_dc, width, height);
            SelectObject(memory_dc, previous);
            DeleteObject(bitmap as *mut c_void);
            DeleteDC(memory_dc);
            ReleaseDC(desktop, desktop_dc);

            let control_visible = bitblt.cyan > 0;
            let protected_visible = bitblt.magenta > 0;

            let verdict = if !control_visible {
                "INVALID: the unprotected control window was not captured either, \
                 so there is no display or no capture at all"
            } else if protected_visible {
                "NOT_EXCLUDED: WDA_EXCLUDEFROMCAPTURE did not remove the window"
            } else if printwindow.magenta > 0 {
                "PARTIAL: excluded from BitBlt but visible to PrintWindow"
            } else {
                "EXCLUDED: absent from every capture path while the control window \
                 in the same frame was captured normally"
            };

            let report = serde_json::json!({
                "probe_version": 1,
                "screen": { "width": width, "height": height },
                "protected_window_affinity": affinity_of(protected),
                "control_window_affinity": affinity_of(control),
                "A_bitblt_screen_dc": { "magenta": bitblt.magenta, "cyan": bitblt.cyan },
                "B_printwindow_desktop": {
                    "magenta": printwindow.magenta, "cyan": printwindow.cyan
                },
                "verdict": verdict,
            });

            let text = serde_json::to_string_pretty(&report).unwrap();
            println!("{text}");
            let path =
                std::env::var("VEIL_PROBE_OUT").unwrap_or_else(|_| "probe-windows.json".into());
            let _ = std::fs::write(path, &text);
            eprintln!("verdict: {verdict}");
        }
    }
}
