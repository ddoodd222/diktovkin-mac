import Foundation

/// Модель распознавания: файл ggml для whisper.cpp.
struct Model {
    let id: String        // small / medium
    let title: String
    let note: String
    let bytes: Int64

    var file: String { "ggml-\(id).bin" }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")! }

    /// Модель, положенная внутрь приложения при сборке. Тогда качать нечего.
    var bundled: URL? { Bundle.main.url(forResource: "ggml-\(id)", withExtension: "bin") }
    /// Куда кладёт закачка.
    var stored: URL { Model.folder.appendingPathComponent(file) }
    var path: URL { bundled ?? stored }

    /// Файл на месте и не обрезан на полпути.
    var isReady: Bool {
        if bundled != nil { return true }
        guard let size = try? FileManager.default.attributesOfItem(atPath: stored.path)[.size] as? Int64 else { return false }
        return size == bytes
    }

    static let all = [
        Model(id: "small-q5_1", title: "small сжатая", note: "190 МБ · в комплекте",       bytes: 190_085_487),
        Model(id: "small",      title: "small",        note: "488 МБ · чуть точнее",       bytes: 487_601_967),
        Model(id: "large-v3-turbo-q5_0", title: "turbo сжатая", note: "574 МБ · точнее medium", bytes: 574_041_195),
        Model(id: "medium",     title: "medium",       note: "1,5 ГБ · точнее, но медленнее", bytes: 1_533_763_059),
        Model(id: "large-v3-turbo", title: "turbo",    note: "1,6 ГБ · точнее всех",       bytes: 1_624_555_275),
    ]

    /// Что предлагать, если человек ничего не выбирал: сначала то, что лежит внутри.
    static var preferred: Model { all.first { $0.bundled != nil } ?? by(id: "small") }

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Diktovkin/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func by(id: String) -> Model { all.first { $0.id == id } ?? all[0] }
}

/// Качает модель один раз и складывает в Application Support. Прогресс — для меню.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    static let shared = Downloader()

    private(set) var active: Model?
    private(set) var progress: Double = 0
    private(set) var error: String?
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    var onChange: (() -> Void)?

    var isRunning: Bool { active != nil }

    func start(_ model: Model) {
        guard active == nil, !model.isReady else { return }
        active = model
        progress = 0
        error = nil
        task = session.downloadTask(with: model.url)
        task?.resume()
        notify()
    }

    func cancel() {
        task?.cancel()
        task = nil
        active = nil
        notify()
    }

    private func notify() { DispatchQueue.main.async { self.onChange?() } }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite expected: Int64) {
        let total = expected > 0 ? expected : (active?.bytes ?? 1)
        progress = Double(written) / Double(total)
        notify()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = active else { return }
        let fm = FileManager.default
        // Пишем через временное имя: оборванная закачка не должна выглядеть готовой моделью.
        let tmp = model.stored.appendingPathExtension("part")
        try? fm.removeItem(at: tmp)
        do {
            try fm.moveItem(at: location, to: tmp)
            try? fm.removeItem(at: model.stored)
            try fm.moveItem(at: tmp, to: model.stored)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError err: Error?) {
        if let err = err as NSError?, err.code != NSURLErrorCancelled { error = err.localizedDescription }
        active = nil
        self.task = nil
        notify()
    }
}
