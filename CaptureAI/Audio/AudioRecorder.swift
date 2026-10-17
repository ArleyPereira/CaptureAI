import AVFoundation
import CoreMedia
import Foundation
import OSLog

/// Encaminha os buffers do `AVCaptureAudioDataOutput` para fora do MainActor,
/// que é o isolamento padrão deste target.
private final class CaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onBuffer: ((CMSampleBuffer) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onBuffer?(sampleBuffer)
    }
}

/// Grava o microfone padrão do sistema em `.m4a` (AAC).
///
/// A saída de captura é forçada para PCM 16 bits / 16 kHz / mono: é o formato
/// esperado pelo Parakeet e evita conversões implícitas no encoder AAC.
final class AudioRecorder: AudioRecorderProtocol, @unchecked Sendable {
    private static let sampleRate: Double = 16_000

    private let logger = Logger(subsystem: "dev.arley.santana.CaptureAI", category: "audio")
    private let session = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let configQueue = DispatchQueue(label: "dev.arley.santana.CaptureAI.capture.config")
    private let sampleQueue = DispatchQueue(label: "dev.arley.santana.CaptureAI.capture.samples")
    private let delegate = CaptureDelegate()
    private let lock = NSLock()

    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var currentFileURL: URL?
    private var sessionStartTime: CMTime?
    private var lastBufferEndTime: CMTime?
    /// `true` enquanto a sessão está aberta (gravando ou pausada).
    private var sessionOpen = false
    /// `true` quando está ativamente capturando buffers.
    private var capturing = false
    private var bufferCount = 0
    private var observedPeak: Float = 0
    private var deviceName = "—"
    private var levelValue: Float = 0
    private var runtimeErrorObserver: NSObjectProtocol?
    /// PCM 16 kHz mono da captura atual — usado pela ASR local sem decodificar o `.m4a`.
    private var pcmSamples: [Float] = []
    /// Energia acumulada bloco a bloco, evitando revarrer o PCM no fim.
    private var speechStats = SpeechEnergyStats()
    /// Finalização do `.m4a` em andamento (encoder AAC + mux), fora do caminho crítico.
    private var finalizationTask: Task<URL, Error>?

    private(set) var lastDiagnostics: CaptureDiagnostics = .empty

    var audioLevel: Float {
        lock.lock()
        defer { lock.unlock() }
        return levelValue
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionOpen
    }

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionOpen && !capturing
    }

    init() {
        delegate.onBuffer = { [weak self] sampleBuffer in
            self?.handle(sampleBuffer)
        }

        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey]
            self?.logger.error("Erro em tempo de execução na sessão de captura: \(String(describing: error))")
        }
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
    }

    // MARK: - AudioRecorderProtocol

    func startRecording() async throws {
        guard await MicrophonePermission.requestAccess() else {
            throw VoiceInputError.microphonePermissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configQueue.async {
                do {
                    try self.beginCapture()
                    continuation.resume()
                } catch {
                    self.logger.error("Falha ao iniciar captura: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stopCapture() async throws -> StoppedCapture {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<StoppedCapture, Error>) in
            configQueue.async {
                self.drainCapture(completion: continuation.resume(with:))
            }
        }
    }

    func finalizedRecording() async throws -> URL {
        guard let task = currentFinalizationTask() else {
            throw VoiceInputError.recordingNotInProgress
        }
        return try await task.value
    }

    /// Leitura síncrona: `NSLock` não pode ser tomado em contexto assíncrono.
    private func currentFinalizationTask() -> Task<URL, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return finalizationTask
    }

    func stopRecording() async throws -> URL {
        _ = try await stopCapture()
        return try await finalizedRecording()
    }

    func pauseRecording() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configQueue.async {
                do {
                    try self.pauseCapture()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func resumeRecording() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configQueue.async {
                do {
                    try self.resumeCapture()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func deleteRecording(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Lê o nível atual e alimenta o medidor da waveform.
    @discardableResult
    func pollMeterLevel() -> Float {
        let level = audioLevel
        LiveAudioMeter.shared.setLevel(level)
        return level
    }

    // MARK: - Ciclo de captura

    private func beginCapture() throws {
        guard !isRecording else { return }

        let device = try resolveInputDevice()
        try configureSession(with: device)

        let fileURL = RecordingStorage.newRecordingURL(fileExtension: "m4a")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        let writer = try AVAssetWriter(url: fileURL, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000
            ]
        )
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else { throw VoiceInputError.recordingFailed }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? VoiceInputError.recordingFailed
        }

        lock.lock()
        assetWriter = writer
        writerInput = input
        currentFileURL = fileURL
        sessionStartTime = nil
        lastBufferEndTime = nil
        bufferCount = 0
        observedPeak = 0
        levelValue = 0
        deviceName = device.localizedName
        pcmSamples.removeAll(keepingCapacity: true)
        speechStats = SpeechEnergyStats()
        sessionOpen = true
        capturing = true
        lock.unlock()

        LiveAudioMeter.shared.reset()
        session.startRunning()
        logger.info("Captura iniciada em \(device.localizedName, privacy: .public) → \(fileURL.lastPathComponent, privacy: .public)")
    }

    private func pauseCapture() throws {
        lock.lock()
        let canPause = sessionOpen && capturing
        lock.unlock()
        guard canPause else { throw VoiceInputError.recordingNotInProgress }

        session.stopRunning()
        sampleQueue.sync { }

        lock.lock()
        capturing = false
        levelValue = 0
        lock.unlock()
        LiveAudioMeter.shared.reset()
        logger.info("Captura pausada.")
    }

    private func resumeCapture() throws {
        lock.lock()
        let canResume = sessionOpen && !capturing
        lock.unlock()
        guard canResume else { throw VoiceInputError.recordingNotInProgress }

        lock.lock()
        capturing = true
        lock.unlock()
        session.startRunning()
        logger.info("Captura retomada.")
    }

    private func configureSession(with device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        let deviceInput = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(deviceInput) else { throw VoiceInputError.recordingFailed }
        session.addInput(deviceInput)

        audioOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        audioOutput.setSampleBufferDelegate(delegate, queue: sampleQueue)
        guard session.canAddOutput(audioOutput) else { throw VoiceInputError.recordingFailed }
        session.addOutput(audioOutput)
    }

    /// Encerra a captura e devolve o PCM **imediatamente**.
    ///
    /// O encoder AAC e o mux do `.m4a` custam caro e a ASR local não precisa do
    /// arquivo — ela transcreve o PCM que já está em memória. Por isso só a
    /// drenagem dos buffers fica no caminho crítico; o resto vai para
    /// `finalizationTask`, que quem precisar do arquivo aguarda depois.
    private func drainCapture(completion: @escaping (Result<StoppedCapture, Error>) -> Void) {
        lock.lock()
        let wasOpen = sessionOpen
        let fileURL = currentFileURL
        let hasWriter = assetWriter != nil && writerInput != nil
        sessionOpen = false
        capturing = false
        levelValue = 0
        finalizationTask = nil
        lock.unlock()

        LiveAudioMeter.shared.reset()

        guard wasOpen, hasWriter, let fileURL else {
            completion(.failure(VoiceInputError.recordingNotInProgress))
            return
        }

        // Sem delegate e com a fila drenada, nenhum buffer novo entra depois
        // daqui — o PCM lido abaixo é o material completo da ditagem.
        audioOutput.setSampleBufferDelegate(nil, queue: nil)
        sampleQueue.sync { }

        lock.lock()
        let samples = pcmSamples
        pcmSamples = []
        let stats = speechStats
        lock.unlock()

        // `writer`/`input` ficam nas propriedades e são lidos lá dentro:
        // `AVAssetWriter` não é `Sendable` e não pode atravessar o Task.
        let task = Task { [weak self] in
            guard let self else { throw VoiceInputError.recordingFailed }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                // Na configQueue para não correr com o beginCapture de uma
                // ditagem seguinte, que reconfigura a mesma AVCaptureSession.
                // Como estamos dentro dela agora, este bloco só roda quando
                // `drainCapture` retornar.
                self.configQueue.async {
                    self.finalizeWriter(fileURL: fileURL, completion: continuation.resume(with:))
                }
            }
        }

        lock.lock()
        finalizationTask = task
        lock.unlock()

        completion(.success(StoppedCapture(pcmSamples: samples, speechStats: stats, fileURL: fileURL)))
    }

    /// Fecha a sessão de captura e o arquivo AAC — fora do caminho crítico.
    private func finalizeWriter(fileURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        lock.lock()
        let writer = assetWriter
        let input = writerInput
        lock.unlock()

        guard let writer, let input else {
            completion(.failure(VoiceInputError.recordingNotInProgress))
            return
        }

        if session.isRunning {
            session.stopRunning()
        }
        input.markAsFinished()

        writer.finishWriting { [weak self] in
            guard let self else { return }
            let writerError = writer.error
            let diagnostics = self.collectDiagnostics(for: fileURL)

            self.lock.lock()
            self.assetWriter = nil
            self.writerInput = nil
            self.currentFileURL = nil
            self.sessionStartTime = nil
            self.lastBufferEndTime = nil
            self.levelValue = 0
            self.lastDiagnostics = diagnostics
            self.lock.unlock()

            LiveAudioMeter.shared.reset()
            self.logger.info("Captura encerrada: \(diagnostics.summary, privacy: .public)")

            if let writerError {
                completion(.failure(writerError))
            } else if diagnostics.receivedNoAudio || diagnostics.byteCount < 512 {
                completion(.failure(VoiceInputError.recordingFailed))
            } else if diagnostics.isSilent {
                completion(.failure(VoiceInputError.emptyRecording))
            } else {
                completion(.success(fileURL))
            }
        }
    }

    private func collectDiagnostics(for fileURL: URL) -> CaptureDiagnostics {
        lock.lock()
        let count = bufferCount
        let peak = observedPeak
        let name = deviceName
        let start = sessionStartTime
        let end = lastBufferEndTime
        lock.unlock()

        let duration: Double
        if let start, let end {
            duration = max(0, CMTimeGetSeconds(CMTimeSubtract(end, start)))
        } else {
            duration = 0
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        return CaptureDiagnostics(
            deviceName: name,
            sampleRate: Self.sampleRate,
            bufferCount: count,
            peakAmplitude: peak,
            durationSeconds: duration,
            byteCount: byteCount,
            fileURL: FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
        )
    }

    // MARK: - Dispositivo

    /// Prefere o microfone marcado como padrão no macOS, casando pelo UID do CoreAudio.
    private func resolveInputDevice() throws -> AVCaptureDevice {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices

        if let uid = SystemAudioDevice.defaultInputDeviceUID,
           let match = discovered.first(where: { $0.uniqueID == uid }) {
            return match
        }

        if let fallback = AVCaptureDevice.default(for: .audio) {
            return fallback
        }

        guard let first = discovered.first else {
            throw VoiceInputError.noInputDevice
        }
        return first
    }

    // MARK: - Buffers

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let isActive = capturing
        let writer = assetWriter
        let input = writerInput
        let alreadyStarted = sessionStartTime != nil
        lock.unlock()

        guard isActive, let writer, let input, writer.status == .writing else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !alreadyStarted {
            writer.startSession(atSourceTime: presentationTime)
            lock.lock()
            sessionStartTime = presentationTime
            lock.unlock()
        }

        measure(sampleBuffer)

        guard input.isReadyForMoreMediaData, input.append(sampleBuffer) else { return }

        lock.lock()
        bufferCount += 1
        lastBufferEndTime = CMTimeAdd(presentationTime, CMSampleBufferGetDuration(sampleBuffer))
        lock.unlock()
    }

    /// Calcula RMS/pico do bloco PCM 16 bits e atualiza o nível exibido.
    private func measure(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mBitsPerChannel == 16,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0 else {
            logger.warning("Formato de bloco inesperado; medição de nível ignorada.")
            return
        }

        var blockBuffer: CMBlockBuffer?
        var bufferList = AudioBufferList()

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let data = bufferList.mBuffers.mData,
              bufferList.mBuffers.mDataByteSize > 0 else { return }

        let samples = data.assumingMemoryBound(to: Int16.self)
        let sampleCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        let scale = 1 / Float(Int16.max)
        let loudThreshold = SpeechPresenceAnalyzer.loudSampleThreshold
        var sumOfSquares: Float = 0
        var peak: Float = 0
        var loudSamples = 0
        var floats = [Float](repeating: 0, count: sampleCount)
        for index in 0..<sampleCount {
            let sample = Float(samples[index]) * scale
            floats[index] = sample
            let absolute = abs(sample)
            sumOfSquares += absolute * absolute
            peak = max(peak, absolute)
            if absolute >= loudThreshold {
                loudSamples += 1
            }
        }

        let rms = (sumOfSquares / Float(sampleCount)).squareRoot()
        // Fala normal fica em RMS ~0,01–0,15; a curva abre essa faixa na waveform.
        let normalized = min(1, (max(rms * 12, peak * 4)).squareRoot())

        lock.lock()
        pcmSamples.append(contentsOf: floats)
        observedPeak = max(observedPeak, peak)
        // Acumula em Double: somar milhões de quadrados em Float perde precisão.
        speechStats.sampleCount += sampleCount
        speechStats.sumSquares += Double(sumOfSquares)
        speechStats.peak = max(speechStats.peak, peak)
        speechStats.loudSampleCount += loudSamples
        levelValue += (normalized - levelValue) * (normalized > levelValue ? 0.6 : 0.25)
        let level = levelValue
        lock.unlock()

        LiveAudioMeter.shared.setLevel(level)
    }
}
