//  veil, macOS vertical slice.
//
//  Wires the parts that are genuinely macOS-specific and genuinely hard:
//  far-end audio via a Core Audio process tap, near-end audio via the mic,
//  endpointing, a non-activating overlay, permission-free share detection and
//  global hotkeys. Transcription and answering are deliberately absent here;
//  they are cross-platform and slot in behind a protocol.
//
//  Hotkeys:  cmd-opt-V toggle overlay   cmd-opt-H panic hide   cmd-opt-R rescan audio

import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class AppController {

    private let overlay = Overlay()
    private let watchdog = ShareWatchdog()
    private let mic = MicCapture()
    private let farVAD = VAD()
    private let nearVAD = VAD()

    private var tap: AnyObject?          // ProcessAudioTap, gated on 14.4
    private var farLevel: Float = 0
    private var nearLevel: Float = 0
    private var turns = 0
    private var lines: [String] = []
    private var hiddenByWatchdog = false

    func start() {
        overlay.show()
        log("veil 0.1.0")
        log(overlay.protectionNote)

        startWatchdog()
        startFarEnd()
        startNearEnd()
        registerHotkeys()

        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    // MARK: far end

    private func startFarEnd() {
        guard #available(macOS 14.4, *) else {
            log("far-end capture needs macOS 14.4 or later (Core Audio process taps)")
            return
        }
        let t = ProcessAudioTap()
        let pids = ProcessAudioTap.conferencingPIDs()
        t.onSamples = { [weak self] samples, asbd in
            let rate = asbd.mSampleRate
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            // Interleaved to mono, cheaply.
            var mono = [Float]()
            mono.reserveCapacity(samples.count / channels)
            var i = 0
            while i + channels <= samples.count {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[i + c] }
                mono.append(sum / Float(channels))
                i += channels
            }
            Task { @MainActor in self?.farVAD.feed(mono, sampleRate: rate) }
        }
        farVAD.onTurnEnded = { [weak self] millis in
            guard let self else { return }
            self.turns += 1
            self.log(String(format: "far end finished a turn (%.1fs) -> this is where the LLM fires", millis / 1000))
        }
        do {
            try t.start(pids: pids)
            tap = t
            let who = pids.isEmpty ? "everything except ourselves" : "\(pids.count) conferencing process(es)"
            log("far-end tap running on \(who)")
        } catch {
            log("far-end tap failed: \(error)")
        }
    }

    // MARK: near end

    private func startNearEnd() {
        mic.onSamples = { [weak self] samples, rate in
            Task { @MainActor in self?.nearVAD.feed(samples, sampleRate: rate) }
        }
        nearVAD.onSpeechStarted = { [weak self] in
            // You started answering, so stop competing for attention.
            self?.overlay.setStatus("you are speaking")
        }
        do { try mic.start(); log("microphone running") }
        catch { log("microphone failed: \(error)") }
    }

    // MARK: watchdog

    private func startWatchdog() {
        watchdog.onChange = { [weak self] signal in
            Task { @MainActor in
                guard let self else { return }
                if signal.sharing {
                    self.hiddenByWatchdog = true
                    self.overlay.hide()
                    NSLog("veil: share detected, overlay hidden. %@", signal.reasons.joined(separator: "; "))
                } else if self.hiddenByWatchdog {
                    self.hiddenByWatchdog = false
                    self.overlay.show()
                    self.log("share ended, overlay back")
                }
            }
        }
        watchdog.start()
        log("share watchdog running, no permissions required")
    }

    // MARK: hotkeys

    private func registerHotkeys() {
        let ok1 = Hotkeys.shared.register(keyCode: UInt32(kVK_ANSI_V), modifiers: Hotkeys.commandOption) {
            Task { @MainActor in self.overlay.toggle() }
        }
        let ok2 = Hotkeys.shared.register(keyCode: UInt32(kVK_ANSI_H), modifiers: Hotkeys.commandOption) {
            Task { @MainActor in self.overlay.hide() }
        }
        let ok3 = Hotkeys.shared.register(keyCode: UInt32(kVK_ANSI_R), modifiers: Hotkeys.commandOption) {
            Task { @MainActor in
                self.log("rescanning audio sources")
                if #available(macOS 14.4, *) { (self.tap as? ProcessAudioTap)?.stop() }
                self.tap = nil
                self.startFarEnd()
            }
        }
        log("hotkeys: cmd-opt-V toggle, cmd-opt-H hide, cmd-opt-R rescan \(ok1 && ok2 && ok3 ? "" : "(some failed to register)")")
    }

    // MARK: presentation

    private func refreshStatus() {
        farLevel = farVAD.lastLevel
        nearLevel = nearVAD.lastLevel
        let signal = watchdog.current
        let bar = { (level: Float) -> String in
            let n = min(10, Int(level * 400))
            return String(repeating: "#", count: n) + String(repeating: ".", count: 10 - n)
        }
        overlay.setStatus("far \(bar(farLevel))  near \(bar(nearLevel))  turns \(turns)  share \(signal.sharing ? "YES" : "no")")
    }

    private func log(_ message: String) {
        lines.append(message)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        overlay.setText(lines.joined(separator: "\n"))
        NSLog("veil: %@", message)
    }
}

// MARK: - entry point

final class Delegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let c = AppController()
            c.start()
            controller = c
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
