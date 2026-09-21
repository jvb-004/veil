//  The overlay.
//
//  An NSPanel, not an NSWindow, and non-activating above all else. A window
//  that steals focus announces itself twice over: the shared window's title
//  bar dims, and whatever the user was typing stops going where they meant.

import AppKit

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class Overlay {

    private let panel: OverlayPanel
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private(set) var protectionNote = ""

    init() {
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        panel.contentView = container

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15, weight: .medium)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 14, height: 12)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scroll)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        protectionNote = ContentProtection.apply(to: panel)
        positionNearCamera()
    }

    /// Top centre, just under the notch. Reading from there keeps your eyes
    /// closest to the lens, which is the part no API can fix for you.
    func positionNearCamera() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.maxY - size.height - 12))
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    var isVisible: Bool { panel.isVisible }
    func toggle() { isVisible ? hide() : show() }

    func setText(_ text: String) {
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }

    func append(_ text: String) {
        textView.string += text
        textView.scrollToEndOfDocument(nil)
    }

    func setStatus(_ text: String) { statusLabel.stringValue = text }
}
