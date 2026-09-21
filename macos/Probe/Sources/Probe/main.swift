//  veil macOS capture-exclusion probe
//
//  Purpose: settle, empirically and per OS build, what a screen-share actually
//  sees of a window that asks not to be seen. Prints a JSON report.
//
//  Method: put a borderless window filled with pure magenta on screen, then try
//  to photograph the screen four different ways and count magenta pixels.
//  Run the whole battery twice: once with sharingType = .readOnly (the control,
//  where the window MUST show up) and once with .none (the claim under test).
//
//  The per-window capture (D) is the discriminator that matters: if the window
//  is missing from a full-screen capture but present in its own window capture,
//  it was excluded. If it is missing from both, it simply never rendered, which
//  is the macOS 26 failure mode and is not stealth, it is a broken window.

import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - helpers

let markerColor = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

/// Await an async call from the main thread while keeping the AppKit runloop alive.
func syncAwait<T>(_ op: @escaping () async throws -> T) -> Result<T, Error> {
    var out: Result<T, Error>?
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { out = .success(try await op()) } catch { out = .failure(error) }
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.02) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return out ?? .failure(ProbeError.timeout)
}

enum ProbeError: Error, CustomStringConvertible {
    case noDisplay, timeout, nilImage
    var description: String {
        switch self {
        case .noDisplay: return "no display returned by SCShareableContent"
        case .timeout:   return "probe timed out"
        case .nilImage:  return "capture returned nil (usually TCC denial)"
        }
    }
}

/// Count pixels close to pure magenta. Negative means the image was unreadable.
func markerPixels(_ image: CGImage?) -> Int {
    guard let image else { return -1 }
    let w = image.width, h = image.height
    guard w > 0, h > 0 else { return -1 }
    let bytesPerRow = w * 4
    let total = h * bytesPerRow
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return -1 }
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
    buf.initialize(repeating: 0, count: total)
    defer { buf.deallocate() }
    guard let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bytesPerRow, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return -1 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var count = 0
    for i in stride(from: 0, to: total, by: 4) {
        if buf[i] > 220, buf[i + 1] < 50, buf[i + 2] > 220 { count += 1 }
    }
    return count
}

// MARK: - capture paths

/// A: modern path. This is what Zoom, Teams, Chrome getDisplayMedia and QuickTime use.
func captureScreenCaptureKit() -> (pixels: Int, error: String?, listed: Bool?, winPID: pid_t) {
    let pid = ProcessInfo.processInfo.processIdentifier
    let result = syncAwait { () async throws -> (CGImage, Bool) in
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ProbeError.noDisplay }
        // Is our own window even offered to a capturer that enumerates windows?
        let listed = content.windows.contains { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = display.width
        cfg.height = display.height
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                             configuration: cfg)
        return (img, listed)
    }
    switch result {
    case .success(let (img, listed)): return (markerPixels(img), nil, listed, pid)
    case .failure(let e):             return (-1, "\(e)", nil, pid)
    }
}

/// B: legacy CoreGraphics path. Deprecated, still used by older capture code.
func captureCGWindowList() -> Int {
    let img = CGWindowListCreateImage(.infinite, [.optionOnScreenOnly],
                                      kCGNullWindowID, [.bestResolution])
    return markerPixels(img)
}

/// C: the screencapture CLI, i.e. what a user pressing Cmd-Shift-3 gets.
func captureCLI() -> Int {
    let path = NSTemporaryDirectory() + "veil-probe-\(UUID().uuidString).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-t", "png", path]
    do { try p.run(); p.waitUntilExit() } catch { return -1 }
    guard p.terminationStatus == 0,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return -1 }
    try? FileManager.default.removeItem(atPath: path)
    return markerPixels(img)
}

/// D: the discriminator. Capture OUR window by id, straight from WindowServer.
/// Marker present here but absent from A/B/C means genuine capture exclusion.
/// Marker absent here too means the window is not rendering at all.
func captureOwnWindow(_ window: NSWindow) -> Int {
    let wid = CGWindowID(window.windowNumber)
    let img = CGWindowListCreateImage(.null, [.optionIncludingWindow], wid,
                                      [.boundsIgnoreFraming, .bestResolution])
    return markerPixels(img)
}

// MARK: - battery

struct Battery {
    var sharingType: String
    var screenCaptureKit: Int
    var screenCaptureKitError: String?
    var listedInShareableContent: Bool?
    var cgWindowListDisplay: Int
    var screencaptureCLI: Int
    var ownWindowBackingStore: Int

    var dict: [String: Any] {
        var d: [String: Any] = [
            "sharing_type": sharingType,
            "A_screencapturekit_display": screenCaptureKit,
            "B_cgwindowlist_display": cgWindowListDisplay,
            "C_screencapture_cli": screencaptureCLI,
            "D_own_window_backing_store": ownWindowBackingStore,
        ]
        if let e = screenCaptureKitError { d["A_error"] = e }
        if let l = listedInShareableContent { d["A_listed_in_shareable_content"] = l }
        return d
    }
}

func runBattery(on window: NSWindow, sharing: NSWindow.SharingType, label: String) -> Battery {
    window.sharingType = sharing
    window.orderFrontRegardless()
    CATransaction.flush()
    pump(1.2)

    let a = captureScreenCaptureKit()
    let b = captureCGWindowList()
    let c = captureCLI()
    let d = captureOwnWindow(window)

    return Battery(sharingType: label,
                   screenCaptureKit: a.pixels,
                   screenCaptureKitError: a.error,
                   listedInShareableContent: a.listed,
                   cgWindowListDisplay: b,
                   screencaptureCLI: c,
                   ownWindowBackingStore: d)
}

// MARK: - audio probe (Core Audio process taps, macOS 14.4+)

func probeAudioTaps() -> [String: Any] {
    var out: [String: Any] = [:]

    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var devID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let devStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                               &addr, 0, nil, &size, &devID)
    out["default_output_device_status"] = Int(devStatus)
    out["default_output_device_id"] = Int(devID)
    out["has_default_output"] = (devStatus == noErr && devID != 0)

    if #available(macOS 14.4, *) {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "veil-probe-tap"
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        out["process_tap_status"] = Int(status)
        out["process_tap_created"] = (status == noErr)
        out["process_tap_id"] = Int(tapID)
        if status == noErr { AudioHardwareDestroyProcessTap(tapID) }
    } else {
        out["process_tap_status"] = "unavailable_below_14_4"
    }
    return out
}

// MARK: - main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 420, height: 300),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.level = .screenSaver
window.backgroundColor = markerColor
window.isOpaque = true
window.hasShadow = false
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
window.orderFrontRegardless()
pump(0.8)

#if arch(arm64)
let archString = "arm64"
#else
let archString = "x86_64"
#endif

let v = ProcessInfo.processInfo.operatingSystemVersion
let osString = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
// The cliff: ScreenCaptureKit is reported to stop honouring sharingType at 15.4.
let pastCliff = (v.majorVersion > 15) || (v.majorVersion == 15 && v.minorVersion >= 4)

let control = runBattery(on: window, sharing: .readOnly, label: "readOnly (control)")
let test    = runBattery(on: window, sharing: .none,     label: "none (under test)")

var verdict = "INCONCLUSIVE"
if control.screenCaptureKit <= 0 && control.cgWindowListDisplay <= 0 && control.screencaptureCLI <= 0 {
    verdict = "NO_CAPTURE_PERMISSION_OR_NO_DISPLAY: control run saw nothing, results meaningless"
} else if test.ownWindowBackingStore <= 0 && control.ownWindowBackingStore > 0 {
    verdict = "WINDOW_STOPPED_RENDERING: sharingType=.none broke the window (macOS 26 failure mode)"
} else {
    let excludedFromSCK = control.screenCaptureKit > 0 && test.screenCaptureKit <= 0
    let excludedFromCG  = control.cgWindowListDisplay > 0 && test.cgWindowListDisplay <= 0
    let excludedFromCLI = control.screencaptureCLI > 0 && test.screencaptureCLI <= 0
    if excludedFromSCK && excludedFromCG && excludedFromCLI {
        verdict = "FULLY_EXCLUDED: sharingType=.none still hides the window from every path"
    } else if !excludedFromSCK && excludedFromCG {
        verdict = "LEGACY_ONLY: hidden from CoreGraphics, VISIBLE to ScreenCaptureKit (so visible in Zoom/Meet/Teams)"
    } else if !excludedFromSCK && !excludedFromCG {
        verdict = "NOT_EXCLUDED: sharingType=.none does nothing on this build"
    } else {
        verdict = "MIXED: see per-path numbers"
    }
}

let report: [String: Any] = [
    "os_version": osString,
    "past_15_4_cliff": pastCliff,
    "arch": archString,
    "screen": ["width": Int(screenFrame.width), "height": Int(screenFrame.height)],
    "window_number": window.windowNumber,
    "control": control.dict,
    "test": test.dict,
    "audio": probeAudioTaps(),
    "verdict": verdict,
]

let data = try! JSONSerialization.data(withJSONObject: report,
                                       options: [.prettyPrinted, .sortedKeys])
let json = String(data: data, encoding: .utf8)!
print(json)

let outPath = ProcessInfo.processInfo.environment["VEIL_PROBE_OUT"] ?? "probe-report.json"
try? json.write(toFile: outPath, atomically: true, encoding: .utf8)

FileHandle.standardError.write("verdict: \(verdict)\n".data(using: .utf8)!)
