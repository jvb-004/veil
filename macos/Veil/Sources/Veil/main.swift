//  veil, macOS.
//
//  far-end audio -> resample -> streaming ASR -> trigger -> Claude -> overlay
//  near-end audio -> streaming ASR -> transcript (and "you are answering now")
//  share watchdog -> hide the overlay before anyone sees it
//
//  Hotkeys:
//    cmd-opt-V  toggle overlay        cmd-opt-H  panic hide
//    cmd-opt-R  rescan audio          cmd-opt-A  answer the last thing they said

import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class AppController {

    private let config = Config.load()
    private let overlay = Overlay()
    private let watchdog = ShareWatchdog()
    private let mic = MicCapture()
    private let farVAD = VAD()
    private let transcript = TranscriptStore()
    private let trigger = Trigger()

    private var tap: AnyObject?
    private var farTranscriber: Transcriber?
    private var nearTranscriber: Transcriber?
    private var answerer: Answerer?

    private var answerBuffer = ""
    private var statusLine = "starting"
    private var hiddenByWatchdog = false
    private var turns = 0

    func start() {
        overlay.show()
        render(header: "veil 0.1.0")

        startWatchdog()
        startTranscription()
        startAnswering()
        startFarEnd()
        startNearEnd()
        registerHotkeys()

        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    // MARK: transcription

    private func startTranscription() {
        guard let key = config.deepgramAPIKey, !key.isEmpty else {
            farTranscriber = NullTranscriber(speaker: .farEnd)
            nearTranscriber = NullTranscriber(speaker: .nearEnd)
            note("no DEEPGRAM_API_KEY, transcription disabled (audio and overlay still work)")
            return
        }

        let far = DeepgramTranscriber(apiKey: key, speaker: .farEnd,
                                      model: config.sttModel, language: config.language)
        far.onSegment = { [weak self] segment in
            Task { @MainActor in self?.handleFarSegment(segment) }
        }
        far.onError = { [weak self] message in
            Task { @MainActor in self?.note(message) }
        }

        let near = DeepgramTranscriber(apiKey: key, speaker: .nearEnd,
                                       model: config.sttModel, language: config.language)
        near.onSegment = { [weak self] segment in
            Task { @MainActor in self?.transcript.apply(segment) }
        }

        do {
            try far.start()
            try near.start()
            farTranscriber = far
            nearTranscriber = near
            note("transcription live (\(config.sttModel))")
        } catch {
            note("transcription failed to start: \(error)")
        }
    }

    private func handleFarSegment(_ segment: TranscriptSegment) {
        transcript.apply(segment)
        if segment.isFinal {
            turns += 1
            trigger.considerFinal(segment.text)
        } else {
            trigger.considerInterim(segment.text)
        }
    }

    // MARK: answering

    private func startAnswering() {
        guard let key = config.anthropicAPIKey, !key.isEmpty else {
            note("no ANTHROPIC_API_KEY, answering disabled")
            return
        }
        answerer = ClaudeAnswerer(apiKey: key,
                                  model: config.model,
                                  persona: config.persona,
                                  userContext: config.userContext)
        note("answering with \(config.model), adaptive thinking at low effort")

        trigger.onFire = { [weak self] decision in
            Task { @MainActor in self?.ask(decision) }
        }
    }

    private func ask(_ decision: Trigger.Decision) {
        guard let answerer else { return }
        answerBuffer = ""
        statusLine = decision.speculative ? "answering early" : "answering"
        render(header: decision.text)

        answerer.answer(question: decision.text,
                        transcript: transcript.context()) { [weak self] token in
            Task { @MainActor in
                guard let self else { return }
                self.answerBuffer += token
                self.render(header: decision.text)
            }
        } onDone: { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .failure(let error) = result { self.note("answer failed: \(error.localizedDescription)") }
                self.statusLine = "ready"
            }
        }
    }

    // MARK: audio

    private func startFarEnd() {
        guard #available(macOS 14.4, *) else {
            note("far-end capture needs macOS 14.4 (Core Audio process taps)")
            return
        }
        let t = ProcessAudioTap()
        let pids = ProcessAudioTap.conferencingPIDs()
        t.onSamples = { [weak self] samples, asbd in
            guard let self else { return }
            let pcm = Resampler.prepare(samples,
                                        channels: max(1, Int(asbd.mChannelsPerFrame)),
                                        sourceRate: asbd.mSampleRate)
            self.farTranscriber?.send(pcm16: pcm)
            let mono = Resampler.toMono(samples, channels: max(1, Int(asbd.mChannelsPerFrame)))
            Task { @MainActor in self.farVAD.feed(mono, sampleRate: asbd.mSampleRate) }
        }
        do {
            try t.start(pids: pids)
            tap = t
            note("far-end tap on \(pids.isEmpty ? "everything but ourselves" : "\(pids.count) call app(s)")")
        } catch {
            note("far-end tap failed: \(error)")
        }
    }

    private func startNearEnd() {
        mic.onSamples = { [weak self] samples, rate in
            guard let self else { return }
            self.nearTranscriber?.send(pcm16: Resampler.prepare(samples, channels: 1, sourceRate: rate))
        }
        do { try mic.start(); note("microphone live") }
        catch { note("microphone failed: \(error)") }
    }

    // MARK: watchdog

    private func startWatchdog() {
        watchdog.onChange = { [weak self] signal in
            Task { @MainActor in
                guard let self else { return }
                if signal.sharing {
                    self.hiddenByWatchdog = true
                    self.overlay.hide()
                    NSLog("veil: share detected, hidden. %@", signal.reasons.joined(separator: "; "))
                } else if self.hiddenByWatchdog {
                    self.hiddenByWatchdog = false
                    self.overlay.show()
                }
            }
        }
        watchdog.start()
    }

    // MARK: hotkeys

    private func registerHotkeys() {
        Hotkeys.shared.register(keyCode: UInt32(kVK_ANSI_V), modifiers: Hotkeys.commandOption) {
            Task { @MainActor in self.overlay.toggle() }
        }
        Hotkeys.shared.register(keyCode: UInt32(kVK_ANSI_H), modifiers: Hotkeys.commandOption) {
            Task { @MainActor in self.overlay.hide() }
        }
        Hotkeys.shared.register(keyCode: UInt32(kVK_ANSI_R), modifiers: Hotkeys.commandOption) {
            Task { @MainActor in
                if #available(macOS 14.4, *) { (self.tap as? ProcessAudioTap)?.stop() }
                self.tap = nil
                self.startFarEnd()
            }
        }
        Hotkeys.shared.register(keyCode: UInt32(kVK_ANSI_A), modifiers: Hotkeys.commandOption) {
            Task { @MainActor in
                guard let last = self.transcript.lastFarEndLine else { return }
                self.trigger.fireManually(last)
            }
        }
    }

    // MARK: presentation

    private func render(header: String) {
        let body = answerBuffer.isEmpty ? "" : "\n\n\(answerBuffer)"
        overlay.setText("\(header)\(body)")
    }

    private func note(_ message: String) {
        NSLog("veil: %@", message)
        if answerBuffer.isEmpty { overlay.setText(message) }
    }

    private func refreshStatus() {
        let level = farVAD.lastLevel
        let bars = min(10, Int(level * 400))
        let meter = String(repeating: "#", count: bars) + String(repeating: ".", count: 10 - bars)
        let sharing = watchdog.current.sharing ? "SHARING" : "clear"
        overlay.setStatus("them \(meter)  turns \(turns)  \(statusLine)  \(sharing)  \(overlay.protectionNote.prefix(1) == "s" ? "flag on" : "flag off")")
    }
}

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
