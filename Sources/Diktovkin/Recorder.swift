import AVFoundation

/// Микрофон. Отдаёт моно 16 кГц float — ровно то, что ест whisper.
final class Recorder {
    static let rate: Double = 16_000
    static let limit: TimeInterval = 300   // страховка: пять минут и стоп

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    private(set) var isRecording = false
    private(set) var startedAt = Date()
    /// Громкость последнего куска, 0…1 — для точки у курсора.
    private(set) var level: Float = 0

    var seconds: TimeInterval { isRecording ? Date().timeIntervalSince(startedAt) : 0 }
    var duration: TimeInterval { Double(samples.count) / Recorder.rate }

    // MARK: - Доступ

    static var accessGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
        default:
            done(false)
        }
    }

    // MARK: - Запись

    func start() throws {
        guard !isRecording else { return }
        lock.lock()
        samples = []
        samples.reserveCapacity(Int(Recorder.rate) * 60)   // не выделяем память на звуковом потоке
        lock.unlock()

        let input = engine.inputNode
        // Именно outputFormat: движок может сам свести каналы, и врезка обязана совпасть с ним.
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw Err.noInput }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Recorder.rate,
                                            channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else { throw Err.noConverter }
        converter = conv

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.append(buffer, to: outFormat)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
        startedAt = Date()
    }

    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        level = 0
        lock.lock(); let out = samples; lock.unlock()
        return out
    }

    // MARK: - Перегон в 16 кГц

    private func append(_ buffer: AVAudioPCMBuffer, to outFormat: AVAudioFormat) {
        guard let conv = converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
        let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = (sum / Float(max(1, chunk.count))).squareRoot()
        // Вверх скачком, вниз плавно: так точка дышит, а не мигает.
        level = max(min(1, rms * 8), level * 0.75)
        lock.lock()
        if Double(samples.count) / Recorder.rate < Recorder.limit { samples.append(contentsOf: chunk) }
        lock.unlock()
    }

    enum Err: Error { case noInput, noConverter, badFile }

    /// Читает звуковой файл в те же моно 16 кГц — для проверки из терминала.
    static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                      channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: file.processingFormat, to: out) else { throw Err.noConverter }
        let frames = AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 4096
        guard let buffer = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: frames) else { throw Err.badFile }

        var done = false
        var err: NSError?
        conv.convert(to: buffer, error: &err) { need, status in
            if done { status.pointee = .endOfStream; return nil }
            guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: need) else {
                status.pointee = .endOfStream; return nil
            }
            do { try file.read(into: chunk) } catch { status.pointee = .endOfStream; return nil }
            if chunk.frameLength == 0 { done = true; status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            return chunk
        }
        if let err { throw err }
        guard let data = buffer.floatChannelData?[0] else { throw Err.badFile }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
