//
//  MicrophoneCapture.swift
//  CallCapture
//

import AVFoundation

/// Captures the default microphone with AVAudioEngine and streams it to a WAV
/// file as it arrives, so a crash loses seconds rather than the whole call.
///
/// Audio is converted to one fixed format before writing, and the engine is
/// rebuilt when the input device or its format changes (e.g. AirPods connect),
/// so the recording keeps going through the switch.
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case noInput
        case unsupportedFormat
        case couldNotRecover(String)
        case tooManyRestarts

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Microphone permission denied"
            case .noInput: "No microphone available"
            case .unsupportedFormat: "Microphone format not supported"
            case .couldNotRecover(let reason): "Microphone couldn't restart after a device change (\(reason))"
            case .tooManyRestarts: "Microphone kept resetting; recording stopped"
            }
        }
    }

    /// me.wav is always written in this format, whatever the mic delivers.
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    )!

    private static let restartDelay: TimeInterval = 0.3
    private static let maxRestartAttempts = 5
    private static let restartLimit = 10
    private static let restartWindow: TimeInterval = 30

    private let fileURL: URL
    private let onFailure: @MainActor @Sendable (Error) -> Void

    // Engine state; accessed only on `controlQueue`.
    private let controlQueue = DispatchQueue(label: "CallCapture.MicrophoneCapture")
    private var engine: AVAudioEngine?
    private var inputFormat: AVAudioFormat?
    private var configObserver: NSObjectProtocol?
    private var isStopped = false
    private var isRestarting = false
    private var recentRestarts: [Date] = []

    // Guarded by `lock`; written from the engine's tap thread.
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var nextHostTime: UInt64?
    private var padNextGap = false

    /// `onFailure` runs on the main actor if capture or writing fails mid-recording.
    init(fileURL: URL, onFailure: @escaping @MainActor @Sendable (Error) -> Void) {
        self.fileURL = fileURL
        self.onFailure = onFailure
    }

    /// Asks for microphone access the first time; afterwards returns the saved answer.
    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let format = Self.outputFormat
        let file = try AVAudioFile(
            forWriting: fileURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        lock.withLock { self.file = file }
        do {
            try controlQueue.sync { try startEngine() }
        } catch {
            stop()
            throw error
        }
    }

    /// Stops the engine and finalizes the WAV header. Safe to call more than once.
    func stop() {
        controlQueue.sync {
            isStopped = true
            tearDownEngine()
        }
        closeFile()
    }

    // MARK: - Engine (run on `controlQueue`)

    /// Builds a fresh engine, since an existing one can keep the old device's format.
    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else { throw CaptureError.noInput }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.outputFormat) else {
            throw CaptureError.unsupportedFormat
        }
        converter.downmix = true
        lock.withLock { self.converter = converter }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.write(buffer, at: time)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        self.engine = engine
        self.inputFormat = inputFormat

        engine.prepare()
        try engine.start()
    }

    private func tearDownEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        inputFormat = nil
    }

    private func handleConfigurationChange() {
        controlQueue.async { [self] in
            guard !isStopped, !isRestarting, let engine else { return }
            // Some changes leave the engine running on the same input; nothing to do.
            if engine.isRunning, engine.inputNode.outputFormat(forBus: 0) == inputFormat { return }

            let now = Date()
            recentRestarts = recentRestarts.filter { now.timeIntervalSince($0) < Self.restartWindow } + [now]
            guard recentRestarts.count <= Self.restartLimit else {
                fail(CaptureError.tooManyRestarts)
                return
            }

            isRestarting = true
            tearDownEngine()
            lock.withLock { padNextGap = true }
            attemptRestart(attempt: 1)
        }
    }

    private func attemptRestart(attempt: Int) {
        // Give the new device a moment to settle before reading its format.
        controlQueue.asyncAfter(deadline: .now() + Self.restartDelay) { [self] in
            guard !isStopped else { return }
            do {
                try startEngine()
                isRestarting = false
            } catch {
                tearDownEngine()
                if attempt < Self.maxRestartAttempts {
                    attemptRestart(attempt: attempt + 1)
                } else {
                    fail(CaptureError.couldNotRecover(error.localizedDescription))
                }
            }
        }
    }

    private func fail(_ error: Error) {
        isStopped = true
        isRestarting = false
        tearDownEngine()
        closeFile()
        report(error)
    }

    // MARK: - Writing (tap thread)

    private func write(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let error: Error? = lock.withLock {
            guard let file, let converter else { return nil }
            do {
                // Fill audio lost during a restart with silence so me.wav stays aligned with them.wav.
                if padNextGap, let nextHostTime, time.isHostTimeValid, time.hostTime > nextHostTime {
                    try Self.writeSilence(seconds: AVAudioTime.seconds(forHostTime: time.hostTime - nextHostTime), to: file)
                }
                padNextGap = false
                try file.write(from: Self.convert(buffer, with: converter))
                if time.isHostTimeValid {
                    let duration = Double(buffer.frameLength) / buffer.format.sampleRate
                    nextHostTime = time.hostTime + AVAudioTime.hostTime(forSeconds: duration)
                }
                return nil
            } catch {
                file.close()
                self.file = nil
                return error
            }
        }
        if let error { report(error) }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw CaptureError.unsupportedFormat
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw conversionError ?? CaptureError.unsupportedFormat }
        return output
    }

    private static func writeSilence(seconds: TimeInterval, to file: AVAudioFile) throws {
        var remaining = AVAudioFrameCount(seconds * outputFormat.sampleRate)
        let chunk = AVAudioFrameCount(outputFormat.sampleRate)
        guard remaining > 0, let silence = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunk) else { return }
        memset(silence.floatChannelData![0], 0, Int(chunk) * MemoryLayout<Float>.size)
        while remaining > 0 {
            silence.frameLength = min(remaining, chunk)
            try file.write(from: silence)
            remaining -= silence.frameLength
        }
    }

    // MARK: - Private

    private func closeFile() {
        lock.withLock {
            file?.close()
            file = nil
            converter = nil
        }
    }

    private func report(_ error: Error) {
        let onFailure = onFailure
        Task { @MainActor in onFailure(error) }
    }
}
