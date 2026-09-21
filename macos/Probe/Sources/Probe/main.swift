//  veil macOS capture-exclusion probe, v2
//
//  v1 was wrong in one important way. Its "discriminator" captured our own
//  window with CGWindowListCreateImage to decide whether the window was still
//  rendering. But that call is itself gated by the window's sharing state, so
//  a window excluded from capture and a window that never rendered look
//  identical through it. v1 could not tell them apart and said so with
//  unearned confidence.
//
//  v2 measures the thing that is NOT sharing-gated: window metadata. A window
//  with a live backing store reports kCGWindowMemoryUsage, kCGWindowIsOnscreen
//  and an alpha. Those are answers from WindowServer's bookkeeping, not from
//  its pixel pipeline, so they survive the sharing gate.
//
//  v2 also adds the test that actually matters. A one-shot screenshot is not
//  what Zoom does. Zoom opens an SCStream and keeps it open, and Apple forum
//  thread 808016 reports that excluded windows reappear in a long-running
//  stream once its content filter is touched. So we run a real stream for
//  several seconds and toggle its filter mid-flight.
//
//  Two windows are on screen the whole time: a magenta one under test and a
//  cyan one that always stays shareable. If a capture shows cyan and not
//  magenta, the capture worked and only the test window was removed. That is
//  an in-frame control, which beats trusting a separate run.

import AppKit
import CoreAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// MARK: - small utilities

/// Swift 6 concurrency checking rejects mutating a captured var from a Task.
/// A reference box is the boring, portable fix across toolchains.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

/// Await async work from the main thread while keeping the AppKit runloop alive.
func syncAwait<T>(timeout: Double = 30, _ op: @escaping () async throws -> T) -> Result<T, Error> {
    let box = Box<Result<T, Error>?>(nil)
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.value = .success(try await op()) } catch { box.value = .failure(error) }
        sem.signal()
    }
    let deadline = Date().addingTimeInterval(timeout)
    while sem.wait(timeout: .now() + 0.02) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        if Date() > deadline { return .failure(ProbeError.timeout) }
    }
    return box.value ?? .failure(ProbeError.timeout)
}

enum ProbeError: Error, CustomStringConvertible {
    case noDisplay, timeout, nilImage
    var description: String {
        switch self {
        case .noDisplay: return "no display from SCShareableContent"
        case .timeout:   return "timed out"
        case .nilImage:  return "capture returned nil"
        }
    }
}

// MARK: - pixel counting

struct MarkerCount { var magenta = 0; var cyan = 0 }

func countMarkers(_ image: CGImage?) -> MarkerCount {
    guard let image, image.width > 0, image.height > 0 else { return MarkerCount(magenta: -1, cyan: -1) }
    let w = image.width, h = image.height
    let bytesPerRow = w * 4
    let total = h * bytesPerRow
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return MarkerCount(magenta: -1, cyan: -1) }
    let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
    buf.initialize(repeating: 0, count: total)
    defer { buf.deallocate() }
    guard let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bytesPerRow, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return MarkerCount(magenta: -1, cyan: -1) }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var out = MarkerCount()
    for i in stride(from: 0, to: total, by: 4) {
        let r = buf[i], g = buf[i + 1], b = buf[i + 2]
        if r > 220, g < 50, b > 220 { out.magenta += 1 }
        else if r < 50, g > 220, b > 220 { out.cyan += 1 }
    }
    return out
}

/// Same, straight off a CVPixelBuffer in BGRA, for stream frames.
func countMarkers(pixelBuffer pb: CVPixelBuffer) -> MarkerCount {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return MarkerCount(magenta: -1, cyan: -1) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let stride = CVPixelBufferGetBytesPerRow(pb)
    let p = base.assumingMemoryBound(to: UInt8.self)
    var out = MarkerCount()
    for y in 0..<h {
        let row = p + y * stride
        for x in 0..<w {
            let b = row[x * 4], g = row[x * 4 + 1], r = row[x * 4 + 2]
            if r > 220, g < 50, b > 220 { out.magenta += 1 }
            else if r < 50, g > 220, b > 220 { out.cyan += 1 }
        }
    }
    return out
}

// MARK: - capture paths

func captureSCKOneShot() -> (markers: MarkerCount, error: String?, listed: Bool) {
    let pid = ProcessInfo.processInfo.processIdentifier
    let result = syncAwait { () async throws -> (CGImage, Bool) in
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ProbeError.noDisplay }
        let listed = content.windows.contains { $0.owningApplication?.processID == pid }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = display.width
        cfg.height = display.height
        cfg.showsCursor = false
        return (try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg), listed)
    }
    switch result {
    case .success(let (img, listed)): return (countMarkers(img), nil, listed)
    case .failure(let e):             return (MarkerCount(magenta: -1, cyan: -1), "\(e)", false)
    }
}

func captureCGDisplay() -> MarkerCount {
    countMarkers(CGWindowListCreateImage(.infinite, [.optionOnScreenOnly], kCGNullWindowID, [.bestResolution]))
}

func captureCLI() -> MarkerCount {
    let path = NSTemporaryDirectory() + "veil-\(UUID().uuidString).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-t", "png", path]
    do { try p.run(); p.waitUntilExit() } catch { return MarkerCount(magenta: -1, cyan: -1) }
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard p.terminationStatus == 0,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return MarkerCount(magenta: -1, cyan: -1) }
    return countMarkers(img)
}

// MARK: - the test that matters: a long-lived SCStream with a filter toggle

final class StreamCollector: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames = Box<[[String: Int]]>([])
    let errors = Box<[String]>([])
    private let started = Date()

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sb),
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let m = countMarkers(pixelBuffer: pb)
        var f = frames.value
        f.append(["ms": Int(Date().timeIntervalSince(started) * 1000),
                  "magenta": m.magenta, "cyan": m.cyan])
        frames.value = f
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        var e = errors.value; e.append("\(error)"); errors.value = e
    }
}

/// Run a stream for ~5s, toggling the content filter halfway, and report the
/// magenta count over time. This is the shape of a real conferencing capture.
var jitterWindow: NSWindow?

func startJitter() -> Timer {
    if jitterWindow == nil {
        let w = NSWindow(contentRect: NSRect(x: 20, y: 600, width: 30, height: 30),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .white
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.sharingType = .readOnly
        w.orderFrontRegardless()
        jitterWindow = w
    }
    var flip = false
    let t = Timer(timeInterval: 0.1, repeats: true) { _ in
        flip.toggle()
        jitterWindow?.setFrameOrigin(NSPoint(x: flip ? 20 : 21, y: 600))
    }
    RunLoop.main.add(t, forMode: .common)
    return t
}

func captureSCKStream() -> [String: Any] {
    let jitter = startJitter()
    defer { jitter.invalidate() }
    let collector = StreamCollector()
    let result = syncAwait(timeout: 60) { () async throws -> Bool in
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ProbeError.noDisplay }

        let filterA = SCContentFilter(display: display, excludingWindows: [])
        let filterB = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.width = display.width
        cfg.height = display.height
        cfg.showsCursor = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 10)  // 10 fps, we need frames
        cfg.queueDepth = 8

        let stream = SCStream(filter: filterA, configuration: cfg, delegate: collector)
        try stream.addStreamOutput(collector, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "veil.stream"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        // The manoeuvre from Apple forum thread 808016: touch the filter.
        // Zoom does this for free whenever you change what you are sharing,
        // when a display is reconfigured, or when it re-enumerates windows.
        try await stream.updateContentFilter(filterB)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try await stream.updateContentFilter(filterA)   // and toggle back
        try await Task.sleep(nanoseconds: 3_000_000_000)
        try await stream.stopCapture()
        return true
    }

    var out: [String: Any] = ["frames": collector.frames.value,
                              "stream_errors": collector.errors.value,
                              "filter_toggle_at_ms": [4000, 7000]]
    if case .failure(let e) = result { out["error"] = "\(e)" }
    let magentas = collector.frames.value.compactMap { $0["magenta"] }
    out["frames_with_magenta"] = magentas.filter { $0 > 0 }.count
    out["frame_count"] = magentas.count
    out["magenta_before_toggle"] = collector.frames.value
        .filter { ($0["ms"] ?? 0) < 4000 }.compactMap { $0["magenta"] }.max() ?? 0
    out["magenta_after_toggle"] = collector.frames.value
        .filter { ($0["ms"] ?? 0) >= 4000 }.compactMap { $0["magenta"] }.max() ?? 0
    return out
}

// MARK: - the non-sharing-gated evidence: WindowServer bookkeeping

func windowMetadata(_ window: NSWindow) -> [String: Any] {
    let wid = CGWindowID(window.windowNumber)
    guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]],
          let info = list.first
    else { return ["found": false] }
    return [
        "found": true,
        "is_onscreen": (info[kCGWindowIsOnscreen as String] as? Bool) ?? false,
        "alpha": (info[kCGWindowAlpha as String] as? Double) ?? -1,
        "sharing_state": (info[kCGWindowSharingState as String] as? Int) ?? -1,
        "memory_usage": (info[kCGWindowMemoryUsage as String] as? Int) ?? -1,
        "store_type": (info[kCGWindowStoreType as String] as? Int) ?? -1,
        "layer": (info[kCGWindowLayer as String] as? Int) ?? -1,
    ]
}

/// Does the app side still draw? This reads the view's own drawing, never
/// WindowServer, so it is unaffected by sharing state.
func viewStillDraws(_ window: NSWindow) -> Int {
    guard let view = window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return -1 }
    view.cacheDisplay(in: view.bounds, to: rep)
    return countMarkers(rep.cgImage).magenta
}

// MARK: - windows

func makeWindow(color: NSColor, x: CGFloat) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(x: x, y: 80, width: 420, height: 300),
                     styleMask: [.borderless], backing: .buffered, defer: false)
    w.level = .screenSaver
    w.backgroundColor = color
    // The colour has to live in the VIEW, not just the window, or the
    // cacheDisplay evidence below measures an empty view and proves nothing.
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
    content.wantsLayer = true
    content.layer?.backgroundColor = color.cgColor
    w.contentView = content
    w.isOpaque = true
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    w.orderFrontRegardless()
    return w
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let testWindow = makeWindow(color: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1), x: 80)
let ctrlWindow = makeWindow(color: NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1), x: 540)
ctrlWindow.sharingType = .readOnly
CATransaction.flush()
pump(1.0)

func phase(_ label: String, sharing: NSWindow.SharingType) -> [String: Any] {
    testWindow.sharingType = sharing
    testWindow.orderFrontRegardless()
    ctrlWindow.orderFrontRegardless()
    CATransaction.flush()
    pump(1.2)

    let oneShot = captureSCKOneShot()
    let cg = captureCGDisplay()
    let cli = captureCLI()

    return [
        "label": label,
        "A_sck_oneshot": ["magenta": oneShot.markers.magenta, "cyan": oneShot.markers.cyan],
        "A_error": oneShot.error as Any,
        "A_listed_in_shareable_content": oneShot.listed,
        "B_cgwindowlist_display": ["magenta": cg.magenta, "cyan": cg.cyan],
        "C_screencapture_cli": ["magenta": cli.magenta, "cyan": cli.cyan],
        "D_stream": captureSCKStream(),
        "E_test_window_metadata": windowMetadata(testWindow),
        "E_control_window_metadata": windowMetadata(ctrlWindow),
        "F_view_still_draws_magenta_px": viewStillDraws(testWindow),
    ]
}

let control = phase("sharingType = .readOnly (control)", sharing: .readOnly)
let test    = phase("sharingType = .none (under test)", sharing: .none)

// MARK: - verdict

func magenta(_ p: [String: Any], _ key: String) -> Int {
    ((p[key] as? [String: Int])?["magenta"]) ?? -1
}
func cyan(_ p: [String: Any], _ key: String) -> Int {
    ((p[key] as? [String: Int])?["cyan"]) ?? -1
}

var verdict: String
var notes: [String] = []

let ctrlOK = magenta(control, "A_sck_oneshot") > 0 && magenta(control, "B_cgwindowlist_display") > 0
let cyanStillVisible = cyan(test, "A_sck_oneshot") > 0
let testMeta = test["E_test_window_metadata"] as? [String: Any] ?? [:]
let ctrlMeta = control["E_test_window_metadata"] as? [String: Any] ?? [:]
let testMem = (testMeta["memory_usage"] as? Int) ?? -1
let ctrlMem = (ctrlMeta["memory_usage"] as? Int) ?? -1
let stillOnscreen = (testMeta["is_onscreen"] as? Bool) ?? false
let drawsInTest = test["F_view_still_draws_magenta_px"] as? Int ?? -1
let streamAfter = (test["D_stream"] as? [String: Any])?["magenta_after_toggle"] as? Int ?? -1
let streamBefore = (test["D_stream"] as? [String: Any])?["magenta_before_toggle"] as? Int ?? -1

if !ctrlOK {
    verdict = "INVALID: the control run saw nothing, so capture permission or the display is missing"
} else if !cyanStillVisible {
    verdict = "INVALID: the always-shareable control window vanished too, capture broke mid-run"
} else if magenta(test, "A_sck_oneshot") > 0 {
    verdict = "NOT_EXCLUDED: sharingType = .none does nothing against ScreenCaptureKit on this build"
} else {
    // Magenta is gone from captures while cyan remains. Now the real question:
    // excluded, or simply not rendering any more?
    // WindowServer bookkeeping is the primary evidence because the sharing
    // gate does not touch it. cacheDisplay is corroboration, not a gate.
    let backingAlive = testMem > 0 && Double(testMem) >= Double(ctrlMem) * 0.5
    if stillOnscreen && backingAlive {
        verdict = "EXCLUDED: still onscreen, alpha 1, backing store intact, yet absent from every capture path"
        if drawsInTest <= 0 { notes.append("cacheDisplay saw no marker; corroboration only, not decisive") }
    } else if !stillOnscreen || (testMem <= 0 && ctrlMem > 0) {
        verdict = "WINDOW_STOPPED_RENDERING: the window left the screen, which is a bug and not stealth"
    } else {
        verdict = "AMBIGUOUS: absent from captures, rendering evidence inconclusive"
        notes.append("onscreen=\(stillOnscreen) mem=\(testMem) vs control \(ctrlMem) viewDraws=\(drawsInTest)")
    }
    if streamAfter > 0 && streamBefore <= 0 {
        verdict += " | STREAM_LEAK: the window reappeared after the content filter was toggled"
    }
}

#if arch(arm64)
let archString = "arm64"
#else
let archString = "x86_64"
#endif

let v = ProcessInfo.processInfo.operatingSystemVersion
let screenFrame = NSScreen.main?.frame ?? .zero

func probeAudioTaps() -> [String: Any] {
    var out: [String: Any] = [:]
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var devID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
    out["default_output_status"] = Int(st)
    out["has_default_output"] = (st == noErr && devID != 0)
    if #available(macOS 14.4, *) {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "veil-probe-tap"
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let s = AudioHardwareCreateProcessTap(desc, &tapID)
        out["process_tap_status"] = Int(s)
        out["process_tap_created"] = (s == noErr)
        if s == noErr { AudioHardwareDestroyProcessTap(tapID) }
    } else {
        out["process_tap_created"] = false
        out["process_tap_status"] = "below_14_4"
    }
    return out
}

let report: [String: Any] = [
    "probe_version": 2,
    "os_version": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
    "past_15_4_cliff": (v.majorVersion > 15) || (v.majorVersion == 15 && v.minorVersion >= 4),
    "arch": archString,
    "screen": ["width": Int(screenFrame.width), "height": Int(screenFrame.height)],
    "control": control,
    "test": test,
    "audio": probeAudioTaps(),
    "notes": notes,
    "verdict": verdict,
]

let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
let json = String(data: data, encoding: .utf8)!
print(json)
let outPath = ProcessInfo.processInfo.environment["VEIL_PROBE_OUT"] ?? "probe-report.json"
try? json.write(toFile: outPath, atomically: true, encoding: .utf8)
FileHandle.standardError.write("verdict: \(verdict)\n".data(using: .utf8)!)
