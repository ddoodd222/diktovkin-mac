import AppKit
import Carbon

// MARK: - Настройки

enum Settings {
    private static let d = UserDefaults.standard

    static var modelID: String {
        get { d.string(forKey: "model") ?? Model.preferred.id }
        set { d.set(newValue, forKey: "model") }
    }
    static var model: Model { Model.by(id: modelID) }

    static var language: String {
        get { d.string(forKey: "language") ?? "ru" }
        set { d.set(newValue, forKey: "language") }
    }
    static var hotkeyIndex: Int {
        get { min(hotkeyPresets.count - 1, max(0, d.integer(forKey: "hotkey"))) }
        set { d.set(newValue, forKey: "hotkey") }
    }
    static var sound: Bool {
        get { d.object(forKey: "sound") as? Bool ?? true }
        set { d.set(newValue, forKey: "sound") }
    }
}

let languages = [("ru", "Русский"), ("en", "Английский"), ("auto", "Определять сам")]

/// Страница доната. Пусто — пункт «Поддержать проект» в меню не показываем.
let donateLink = ""

// MARK: - Горячая клавиша

struct HotkeyPreset {
    let title: String
    let key: UInt32
    let mods: UInt32
}

// ⌥Пробел стоит вторым нарочно: в русской раскладке это неразрывный пробел, он нужен в текстах.
let hotkeyPresets: [HotkeyPreset] = [
    HotkeyPreset(title: "⌃ ⌥ Пробел", key: UInt32(kVK_Space),   mods: UInt32(controlKey | optionKey)),
    HotkeyPreset(title: "⌥ Пробел",   key: UInt32(kVK_Space),   mods: UInt32(optionKey)),
    HotkeyPreset(title: "⌘ ⇧ D",      key: UInt32(kVK_ANSI_D),  mods: UInt32(cmdKey | shiftKey)),
    HotkeyPreset(title: "⌃ ⌥ D",      key: UInt32(kVK_ANSI_D),  mods: UInt32(controlKey | optionKey)),
]

private func hotkeyHandler(_ call: EventHandlerCallRef?, _ event: EventRef?,
                           _ user: UnsafeMutableRawPointer?) -> OSStatus {
    HotkeyCenter.shared.onPress?()
    return noErr
}

/// Глобальный хоткей через Carbon: прав доступа не просит, чужие нажатия не читает.
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var ref: EventHotKeyRef?
    private var installed = false
    var onPress: (() -> Void)?

    func apply(_ preset: HotkeyPreset) {
        if !installed {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &spec, nil, nil)
            installed = true
        }
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        let id = EventHotKeyID(signature: OSType(0x44494B54), id: 1)   // "DIKT"
        RegisterEventHotKey(preset.key, preset.mods, id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Вставка текста

/// Кладёт текст в то окно, которое было активным. Через буфер обмена — он потом возвращается на место.
enum Inserter {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]
    private static let queue = DispatchQueue(label: "diktovkin.paste")

    static var hasAccess: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func paste(_ text: String, into app: NSRunningApplication?, done: @escaping (Bool) -> Void) {
        guard !Bool(IsSecureEventInputEnabled()) else { done(false); return }   // поле пароля — молчим
        if let app, !app.isActive { app.activate() }

        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)

        queue.async {
            waitForModifiersReleased()
            sendCommandV()
            DispatchQueue.main.async { done(true) }   // текст уже в окне
            usleep(300_000)                            // даём приложению дочитать буфер
            DispatchQueue.main.async { restore(pb, saved) }
        }
    }

    // MARK: Буфер обмена

    private static func snapshot(_ pb: NSPasteboard) -> Snapshot {
        (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let x = item.data(forType: t) { d[t] = x } }
            return d
        }
    }

    private static func restore(_ pb: NSPasteboard, _ s: Snapshot) {
        pb.clearContents()
        guard !s.isEmpty else { return }
        pb.writeObjects(s.map { d in
            let item = NSPasteboardItem()
            for (t, x) in d { item.setData(x, forType: t) }
            return item
        })
    }

    // MARK: Клавиши

    /// Человек мог не отпустить ⌥ после хоткея: тогда вместо ⌘V уйдёт ⌘⌥V.
    private static func waitForModifiersReleased() {
        let mods: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        for _ in 0..<75 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(mods).isEmpty { return }
            usleep(20_000)
        }
    }

    private static func sendCommandV() {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        usleep(12_000)
        up.post(tap: .cgSessionEventTap)
    }
}
