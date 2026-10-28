import AppKit
import Carbon.HIToolbox

struct Hotkey: Codable, Equatable {
    var keyCode: Int
    var modifiers: UInt
    var label: String

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt {
        var modifiers: UInt = 0
        if flags.contains(.command) { modifiers |= UInt(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt(optionKey) }
        if flags.contains(.control) { modifiers |= UInt(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt(shiftKey) }
        return modifiers
    }

    static func label(for event: NSEvent) -> String {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + keyName(event)
    }

    private static func keyName(_ event: NSEvent) -> String {
        let names: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        if let name = names[event.keyCode] { return name }
        return event.charactersIgnoringModifiers?.uppercased() ?? "?"
    }
}

struct HotkeyBinding {
    let keyCode: Int
    let modifiers: UInt
    let action: () -> Void
}

/// Global hotkeys via Carbon's RegisterEventHotKey — works without Accessibility permission.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [EventHotKeyRef?] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    /// Returns the ids of the hotkeys the system accepted (a combo another app owns fails).
    @discardableResult
    func register(_ bindings: [HotkeyBinding]) -> [UInt32] {
        unregisterAll()
        installHandlerIfNeeded()
        var registered: [UInt32] = []
        for binding in bindings {
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x444B4D46), id: id) // 'DKMF'
            let status = RegisterEventHotKey(
                UInt32(binding.keyCode), UInt32(binding.modifiers), hotKeyID,
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr {
                refs.append(ref)
                actions[id] = binding.action
                registered.append(id)
            }
        }
        return registered
    }

    private func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs = []
        actions = [:]
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            HotkeyCenter.shared.fire(hotKeyID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}
