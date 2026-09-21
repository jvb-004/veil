//  Global hotkeys via Carbon's RegisterEventHotKey.
//
//  Chosen over a CGEvent tap on purpose: an event tap needs Accessibility
//  permission, which is both a prompt and a TCC record. This route needs
//  neither and has worked unchanged since the beginning of time.

import AppKit
import Carbon.HIToolbox

final class Hotkeys {

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    static let shared = Hotkeys()

    private init() { installHandler() }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let me = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.handlers[hotKeyID.id]?() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// `keyCode` is a virtual key constant such as `kVK_ANSI_V`.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        let id = EventHotKeyID(signature: OSType(0x5645494C), id: nextID)  // 'VEIL'
        handlers[nextID] = action
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
        return status == noErr
    }

    static let commandOption = UInt32(cmdKey | optionKey)
    static let commandShift = UInt32(cmdKey | shiftKey)
}
