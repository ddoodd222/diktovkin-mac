import AppKit
import ServiceManagement

// Проверка из терминала: Diktovkin --file запись.wav [ru|en|auto]
let cliArgs = CommandLine.arguments
if cliArgs.count > 2, cliArgs[1] == "--file" {
    let model = Settings.model
    guard model.isReady else { print("Нет модели \(model.title): \(model.path.path)"); exit(1) }
    guard let samples = try? Recorder.load(URL(fileURLWithPath: cliArgs[2])) else { print("Не читается файл"); exit(1) }
    let lang = cliArgs.count > 3 ? cliArgs[3] : Settings.language
    let t0 = Date()
    Whisper.shared.preload(model)
    let wait = DispatchSemaphore(value: 0)
    var out: String?
    var problem: String?
    Whisper.shared.transcribe(samples, model: model, language: lang) { text, error in
        out = text; problem = error; wait.signal()
    }
    // Ответ приходит на главную очередь, поэтому крутим runloop, а не блокируем её.
    while wait.wait(timeout: .now() + 0.02) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    print(out ?? "— \(problem ?? "пусто")")
    print(String(format: "звук %.1f с · модель %.2f с · распознавание %.2f с · всего %.2f с",
                 Double(samples.count) / Recorder.rate, Whisper.shared.lastLoad, Whisper.shared.lastRun,
                 Date().timeIntervalSince(t0)))
    exit(out == nil ? 1 : 0)
}

enum State { case idle, recording, thinking }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let recorder = Recorder()
    private var state: State = .idle
    private var ticker: Timer?
    private var target: NSRunningApplication?   // окно, куда вернём текст
    private var stoppedAt: Date?
    private var lastLatency: Double?
    private var lastText: String?
    private var note: String?                   // короткая жалоба в меню

    // MARK: - Запуск

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu.delegate = self
        statusItem.menu = menu

        Indicator.shared.state = { [weak self] in
            guard let self else { return (.listening, "", 0) }
            if self.state == .thinking { return (.thinking, self.percent(Whisper.shared.progress), 0) }
            return (.listening, self.clock(self.recorder.seconds), self.recorder.level)
        }
        HotkeyCenter.shared.onPress = { [weak self] in self?.hotkeyPressed() }
        HotkeyCenter.shared.apply(hotkeyPresets[Settings.hotkeyIndex])
        Downloader.shared.onChange = { [weak self] in self?.refresh() }

        if !Inserter.hasAccess { Inserter.requestAccess() }
        Recorder.requestAccess { _ in self.refresh() }
        if !Settings.model.isReady { Downloader.shared.start(Settings.model) }
        refresh()
    }

    // MARK: - Диктовка

    private func hotkeyPressed() {
        switch state {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .thinking: NSSound.beep()
        }
    }

    private func startRecording() {
        guard Settings.model.isReady else {
            note = Downloader.shared.isRunning ? "Модель ещё качается" : "Нет модели"
            if !Downloader.shared.isRunning { Downloader.shared.start(Settings.model) }
            NSSound.beep(); refresh(); return
        }
        guard Recorder.accessGranted else {
            note = "Нет доступа к микрофону"
            Recorder.requestAccess { _ in self.refresh() }
            NSSound.beep(); refresh(); return
        }
        do {
            try recorder.start()
        } catch {
            note = "Микрофон не открылся"
            NSSound.beep(); refresh(); return
        }
        target = NSWorkspace.shared.frontmostApplication
        note = nil
        state = .recording
        // Пока человек говорит, модель успевает подняться в память.
        Whisper.shared.preload(Settings.model)
        Whisper.shared.onProgress = { [weak self] in self?.refresh() }
        Sounds.play(Settings.soundStart)
        Indicator.shared.show()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.recorder.seconds > Recorder.limit { self.stopRecording() } else { self.refresh() }
        }
        refresh()
    }

    private func stopRecording() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        stoppedAt = Date()
        state = .thinking
        Sounds.play(Settings.soundStop)
        refresh()

        Whisper.shared.transcribe(samples, model: Settings.model, language: Settings.language) { [weak self] text, error in
            guard let self else { return }
            guard let text else {
                self.note = error
                self.finish(success: false)
                return
            }
            self.lastText = text
            guard Inserter.hasAccess else {
                // Без «Универсального доступа» нажать ⌘V за человека нельзя — оставляем текст в буфере.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.note = "Текст в буфере: нажми ⌘V"
                Inserter.requestAccess()
                self.finish(success: false)
                return
            }
            Inserter.paste(text, into: self.target) { ok in
                self.note = ok ? nil : "Не вставилось: поле пароля?"
                self.finish(success: ok)
            }
        }
    }

    private func finish(success: Bool) {
        if let stoppedAt, success { lastLatency = Date().timeIntervalSince(stoppedAt) }
        if !success { NSSound.beep() }
        state = .idle
        Indicator.shared.hide()
        ticker?.invalidate()
        ticker = nil
        refresh()
    }

    // MARK: - Строка меню

    private func refresh() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.contentTintColor = nil

        var symbol = "mic"
        var title = ""
        if Downloader.shared.isRunning {
            symbol = "arrow.down.circle"
            title = percent(Downloader.shared.progress)
        }
        switch state {
        case .idle:
            if !Recorder.accessGranted { symbol = "mic.slash" }
        case .recording:
            symbol = "mic.fill"
            button.contentTintColor = .systemRed
            title = clock(recorder.seconds)
        case .thinking:
            symbol = "waveform"
            title = percent(Whisper.shared.progress)
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Диктовкин")
        button.image?.isTemplate = true
        button.title = title.isEmpty ? "" : " \(title)"
    }

    private func clock(_ s: TimeInterval) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }

    private func percent(_ v: Double) -> String { "\(Int(v * 100)) %" }

    // MARK: - Меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusLine()))
        if let note { menu.addItem(disabled(note)) }
        if let lastLatency { menu.addItem(disabled(String(format: "Вставка заняла %.1f с", lastLatency))) }
        if let lastText, !lastText.isEmpty {
            menu.addItem(disabled("«\(lastText.prefix(60))\(lastText.count > 60 ? "…" : "")»"))
        }
        menu.addItem(.separator())

        menu.addItem(submenu("Горячая клавиша", items: hotkeyPresets.enumerated().map { i, hk in
            item(hk.title, on: Settings.hotkeyIndex == i, action: #selector(setHotkey(_:)), object: i)
        }))

        menu.addItem(submenu("Модель", items: Model.all.map { m in
            let ready = m.isReady
            let mark = ready ? "" : (Downloader.shared.active?.id == m.id ? " · качается" : " · скачать")
            return item("\(m.title) — \(m.note)\(mark)", on: Settings.modelID == m.id && ready,
                        action: #selector(setModel(_:)), object: m.id)
        }))

        menu.addItem(submenu("Язык", items: languages.map { code, name in
            item(name, on: Settings.language == code, action: #selector(setLanguage(_:)), object: code)
        }))

        menu.addItem(submenu("Звук начала", items: soundItems(Settings.soundStart, #selector(setStartSound(_:)))))
        menu.addItem(submenu("Звук конца", items: soundItems(Settings.soundStop, #selector(setStopSound(_:)))))
        menu.addItem(item("Плашка у курсора", on: Settings.showIndicator,
                          action: #selector(toggleIndicator), object: nil))
        menu.addItem(.separator())

        menu.addItem(item("Запускать при входе", on: SMAppService.mainApp.status == .enabled,
                          action: #selector(toggleLogin), object: nil))
        menu.addItem(item("Открыть настройки доступа…", on: false, action: #selector(openAccess), object: nil))
        if !donateLink.isEmpty {
            menu.addItem(.separator())
            menu.addItem(item("Поддержать проект…", on: false, action: #selector(openDonate), object: nil))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func statusLine() -> String {
        let model = Settings.model
        if Downloader.shared.isRunning {
            return "Качаю модель \(Downloader.shared.active?.title ?? "") — \(percent(Downloader.shared.progress))"
        }
        if let err = Downloader.shared.error { return "Не скачалось: \(err)" }
        if !model.isReady { return "Модель \(model.title) не скачана" }
        switch state {
        case .recording: return "Пишу — \(hotkeyPresets[Settings.hotkeyIndex].title) остановит"
        case .thinking:  return "Распознаю — \(percent(Whisper.shared.progress))"
        case .idle:      return "Жду — \(hotkeyPresets[Settings.hotkeyIndex].title) начнёт"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, on: Bool, action: Selector, object: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let sub = NSMenu()
        items.forEach { sub.addItem($0) }
        let head = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        head.submenu = sub
        return head
    }

    // MARK: - Действия меню

    @objc private func setHotkey(_ sender: NSMenuItem) {
        Settings.hotkeyIndex = sender.representedObject as? Int ?? 0
        HotkeyCenter.shared.apply(hotkeyPresets[Settings.hotkeyIndex])
    }

    @objc private func setModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.modelID = id
        note = nil
        Whisper.shared.unload()
        if !Settings.model.isReady { Downloader.shared.start(Settings.model) }
        refresh()
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        Settings.language = sender.representedObject as? String ?? "ru"
    }

    /// Тишина, системные звуки, свой файл. Свой остается в списке отдельной строкой.
    private func soundItems(_ current: String, _ action: Selector) -> [NSMenuItem] {
        let own = Sounds.own + (action == #selector(setStartSound(_:)) ? "start" : "stop")
        var items = [item("Диктовкин", on: current == own, action: action, object: own)]
        items.append(item("Без звука", on: current.isEmpty, action: action, object: ""))
        items.append(.separator())
        for name in Sounds.system {
            items.append(item(name, on: current == name, action: action, object: name))
        }
        items.append(.separator())
        if current.hasPrefix("/") {
            items.append(item(Sounds.title(current), on: true, action: action, object: current))
        }
        items.append(item("Выбрать свой файл…", on: false, action: action, object: "pick"))
        return items
    }

    @objc private func setStartSound(_ sender: NSMenuItem) {
        guard let spec = pickedSpec(sender, name: "start") else { return }
        Settings.soundStart = spec
        Sounds.play(spec)
    }

    @objc private func setStopSound(_ sender: NSMenuItem) {
        guard let spec = pickedSpec(sender, name: "stop") else { return }
        Settings.soundStop = spec
        Sounds.play(spec)
    }

    private func pickedSpec(_ sender: NSMenuItem, name: String) -> String? {
        guard let spec = sender.representedObject as? String else { return nil }
        return spec == "pick" ? Sounds.pick(as: name) : spec
    }

    @objc private func toggleIndicator() {
        Settings.showIndicator.toggle()
        if !Settings.showIndicator { Indicator.shared.hide() }
        else if state != .idle { Indicator.shared.show() }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openDonate() {
        guard let url = URL(string: donateLink) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openAccess() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
