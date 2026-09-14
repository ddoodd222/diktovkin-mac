import Foundation

/// Обёртка над whisper.cpp. Модель живёт в памяти между диктовками и сама выгружается,
/// если её долго не трогали: первая диктовка ждёт загрузку, остальные — нет.
final class Whisper {
    static let shared = Whisper()

    private var ctx: OpaquePointer?
    private var loaded: String?           // id модели, которая сейчас в памяти
    private var lastUse = Date()
    private var idleTimer: Timer?
    private let queue = DispatchQueue(label: "diktovkin.whisper", qos: .userInitiated)
    private let idleLimit: TimeInterval = 600

    /// 0…1 во время распознавания, для строки меню.
    private(set) var progress: Double = 0
    /// Сколько ушло на подъём модели и на само распознавание — для замеров.
    private(set) var lastLoad: Double = 0
    private(set) var lastRun: Double = 0
    var onProgress: (() -> Void)?

    var isLoaded: Bool { ctx != nil }

    private init() {
        // Логи whisper.cpp в консоль не нужны.
        whisper_log_set({ _, _, _ in }, nil)
    }

    /// Греем модель заранее — обычно пока человек говорит.
    func preload(_ model: Model) {
        queue.async { _ = self.context(for: model) }
        DispatchQueue.main.async { self.armIdleTimer() }
    }

    func unload() {
        queue.async {
            guard let c = self.ctx else { return }
            whisper_free(c)
            self.ctx = nil
            self.loaded = nil
        }
    }

    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.isLoaded, Date().timeIntervalSince(self.lastUse) > self.idleLimit else { return }
            self.unload()
        }
    }

    private func context(for model: Model) -> OpaquePointer? {
        lastUse = Date()
        if let ctx, loaded == model.id { return ctx }
        if let ctx { whisper_free(ctx); self.ctx = nil; loaded = nil }
        guard model.isReady else { return nil }
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let c = whisper_init_from_file_with_params(model.path.path, params) else { return nil }
        ctx = c
        loaded = model.id
        return c
    }

    /// Распознаёт и возвращает готовый текст. Всё локально, звук никуда не уходит.
    func transcribe(_ samples: [Float], model: Model, language: String,
                    done: @escaping (String?, String?) -> Void) {
        queue.async { [self] in
            progress = 0
            guard samples.count > Int(Recorder.rate / 5) else {   // меньше 0,2 с — это промах по клавише
                DispatchQueue.main.async { done(nil, "Слишком коротко") }
                return
            }
            let t0 = Date()
            guard let c = context(for: model) else {
                DispatchQueue.main.async { done(nil, "Модель не загрузилась") }
                return
            }
            lastLoad = Date().timeIntervalSince(t0)
            lastUse = Date()

            var p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            p.n_threads = Int32(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
            p.print_progress = false
            p.print_realtime = false
            p.print_timestamps = false
            p.print_special = false
            p.translate = false
            p.no_timestamps = true
            p.no_context = true              // каждая диктовка сама по себе
            p.suppress_blank = true
            p.suppress_nst = true            // без «[музыка]» и прочего не-речевого
            p.temperature = 0
            p.greedy.best_of = 1
            p.progress_callback = { _, _, value, user in
                guard let user else { return }
                let me = Unmanaged<Whisper>.fromOpaque(user).takeUnretainedValue()
                me.progress = Double(value) / 100
                DispatchQueue.main.async { me.onProgress?() }
            }
            p.progress_callback_user_data = Unmanaged.passUnretained(self).toOpaque()

            let auto = language == "auto"
            let code = auto ? "auto" : language
            let t1 = Date()
            let ok: Int32 = code.withCString { lang in
                p.language = lang
                p.detect_language = false
                return whisper_full(c, p, samples, Int32(samples.count))
            }
            lastRun = Date().timeIntervalSince(t1)
            guard ok == 0 else {
                DispatchQueue.main.async { done(nil, "Распознавание не удалось") }
                return
            }

            var parts: [String] = []
            for i in 0..<whisper_full_n_segments(c) {
                guard let raw = whisper_full_get_segment_text(c, i) else { continue }
                parts.append(String(cString: raw))
            }
            let text = Whisper.clean(parts.joined())
            DispatchQueue.main.async { done(text.isEmpty ? nil : text, text.isEmpty ? "Ничего не услышал" : nil) }
        }
    }

    /// Убирает пометки вида [музыка], (аплодисменты) и лишние пробелы.
    static func clean(_ s: String) -> String {
        var t = s
        for pattern in ["\\[[^\\]]*\\]", "\\([^\\)]*\\)", "\\*[^\\*]*\\*", "♪+"] {
            t = t.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
