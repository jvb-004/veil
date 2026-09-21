//  S0: know when you are being filmed.
//
//  This is the layer nobody in this category ships, and on macOS 15.4+ it is
//  worth more than the flag everyone argues about. It needs no permissions at
//  all: no Screen Recording, no Accessibility, no TCC prompt of any kind.
//
//  Two public signals, neither of which requires reading window titles:
//
//  1. Zoom forks a helper process called CptHost when, and only when, a screen
//     share starts. Its presence is close to a boolean for "Zoom is sharing".
//  2. Conferencing apps raise a small always-on-top control bar the moment a
//     share begins. CGWindowListCopyWindowInfo gives owner name, layer and
//     bounds without any permission; only the title is gated. A short, wide,
//     high-layer window owned by a conferencing app, that was not there ten
//     seconds ago, is a sharing bar.

import AppKit
import CoreGraphics
import Foundation

struct ShareSignal {
    var sharing: Bool
    var confidence: Double
    var reasons: [String]
}

final class ShareWatchdog {

    /// Helper processes that exist only while a share is running.
    private static let shareHelperProcesses: Set<String> = [
        "CptHost",                 // Zoom screen share helper
        "ZoomShareHelper",
        "MSTeamsSharingHelper",
    ]

    private static let conferencingOwners: Set<String> = [
        "zoom.us", "Zoom", "Microsoft Teams", "Google Chrome", "Chrome",
        "Slack", "Webex", "Discord", "Safari", "Arc", "Firefox",
    ]

    private var timer: Timer?
    private var lastSignal = ShareSignal(sharing: false, confidence: 0, reasons: [])

    /// Fired only when the answer changes, not on every poll.
    var onChange: ((ShareSignal) -> Void)?

    func start(interval: TimeInterval = 0.5) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() { timer?.invalidate(); timer = nil }

    var current: ShareSignal { lastSignal }

    private func poll() {
        var reasons: [String] = []
        var score = 0.0

        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            else { continue }
            if Self.shareHelperProcesses.contains(name) {
                reasons.append("share helper process running: \(name)")
                score += 0.8
            }
        }

        if let bars = sharingBars(), !bars.isEmpty {
            reasons.append("sharing control bar visible: \(bars.joined(separator: ", "))")
            score += 0.6
        }

        let signal = ShareSignal(sharing: score >= 0.6,
                                 confidence: min(score, 1.0),
                                 reasons: reasons)
        if signal.sharing != lastSignal.sharing {
            lastSignal = signal
            onChange?(signal)
        } else {
            lastSignal = signal
        }
    }

    /// Short, wide, high-layer windows owned by conferencing apps.
    private func sharingBars() -> [String]? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        var found: [String] = []
        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  Self.conferencingOwners.contains(owner),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer > 0,                                     // above normal windows
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            // A control bar, not a meeting window: short and not full width.
            if rect.height > 20, rect.height < 90, rect.width > 120, rect.width < 900 {
                found.append("\(owner) \(Int(rect.width))x\(Int(rect.height))")
            }
        }
        return found
    }
}
