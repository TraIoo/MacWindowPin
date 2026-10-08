import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyName: String
    static let `default` = Shortcut(keyCode: 35, modifiers: UInt32(controlKey | optionKey), keyName: "P")
    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }
    static func load() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: "shortcut"),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .default }
        return shortcut
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "shortcut") }
}

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private(set) var shortcut: Shortcut?
    var onPress: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let data, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x5750494E, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<HotKey>.fromOpaque(data).takeUnretainedValue()
            owner.onPress?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ value: Shortcut) -> OSStatus {
        if shortcut == value && reference != nil { return noErr }
        var next: EventHotKeyRef?
        let result = RegisterEventHotKey(value.keyCode, value.modifiers, EventHotKeyID(signature: 0x5750494E, id: 1),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &next)
        if result == noErr {
            if let reference { UnregisterEventHotKey(reference) }
            reference = next; shortcut = value
        }
        return result
    }
    func stop() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil; shortcut = nil
    }
    deinit { stop(); if let handler { RemoveEventHandler(handler) } }
}

final class ShortcutRecorder: NSTextField {
    var value: Shortcut = .default { didSet { stringValue = value.label } }
    var recorded: ((Shortcut) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); stringValue = "请按新快捷键…" }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { stringValue = value.label; window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
            97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        value = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyName: names[event.keyCode] ?? chars.uppercased())
        recorded?(value)
        window?.makeFirstResponder(nil)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
}
