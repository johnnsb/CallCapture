//
//  Recorder.swift
//  CallCapture
//

import AppKit
import Foundation
import Observation
import ScreenCaptureKit

/// Owns recording state. Every recording starts through `startRecording()`,
/// so a consent gate can later sit in front of that one call.
///
/// Transcription runs separately: each stopped recording joins a queue that is
/// transcribed in the background, so a new recording can start at any time.
@Observable
final class Recorder {
    enum State: Equatable {
        case idle
        case starting
        case recording
    }

    private(set) var state: State = .idle
    private(set) var startDate: Date?
    private(set) var elapsed: TimeInterval = 0
    private(set) var errorMessage: String?
    private(set) var transcriptionPhase: Transcriber.Phase?
    private(set) var lastTranscriptURL: URL?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var systemAudio: SystemAudioCapture?
    @ObservationIgnored private var microphone: MicrophoneCapture?
    @ObservationIgnored private var currentFolder: URL?
    @ObservationIgnored private var pendingTranscriptions: [URL] = []
    @ObservationIgnored private var isTranscribing = false

    static let recordingsFolder = URL.documentsDirectory.appending(path: "CallCaptures", directoryHint: .isDirectory)

    init() {
        lastTranscriptURL = Self.findLastTranscript()
    }

    var isRecording: Bool { state == .recording }

    var statusText: String {
        let transcription = transcriptionPhase.map { Self.describe($0) }
        switch state {
        case .starting:
            return "Starting…"
        case .recording:
            let recording = "Recording \(Self.format(elapsed))"
            return transcription.map { "\(recording) · \($0)" } ?? recording
        case .idle:
            if let transcription { return transcription }
            if let errorMessage { return "Error: \(errorMessage)" }
            return "Idle"
        }
    }

    func toggle() {
        switch state {
        case .recording: Task { await stopRecording() }
        case .starting: break
        case .idle: startRecording()
        }
    }

    func startRecording() {
        guard state == .idle else { return }
        state = .starting
        errorMessage = nil
        Task { await beginCapture() }
    }

    /// Stops both tracks and closes their files, then queues the call for
    /// transcription unless `transcribe` is false.
    func stopRecording(transcribe: Bool = true) async {
        guard let folder = currentFolder else { return }
        currentFolder = nil
        stopTimer()
        if let microphone {
            self.microphone = nil
            microphone.stop()
        }
        if let systemAudio {
            self.systemAudio = nil
            await systemAudio.stop()
        }
        state = .idle
        if transcribe { enqueueTranscription(of: folder) }
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    func openLastTranscript() {
        if let url = lastTranscriptURL, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            NSWorkspace.shared.open(url)
        } else {
            lastTranscriptURL = Self.findLastTranscript()
            if let lastTranscriptURL { NSWorkspace.shared.open(lastTranscriptURL) }
        }
    }

    // MARK: - Capture

    private func beginCapture() async {
        var folder: URL?
        do {
            // Check the mic first so a denial fails before anything starts.
            guard await MicrophoneCapture.requestPermission() else {
                throw MicrophoneCapture.CaptureError.permissionDenied
            }
            let callFolder = try Self.makeCallFolder()
            folder = callFolder
            let systemAudio = SystemAudioCapture(fileURL: callFolder.appending(path: "them.wav")) { [weak self] error in
                self?.captureFailed(error)
            }
            let microphone = MicrophoneCapture(fileURL: callFolder.appending(path: "me.wav")) { [weak self] error in
                self?.captureFailed(error)
            }
            // System audio is slower to start, so the mic starts right after it.
            try await systemAudio.start()
            do {
                try microphone.start()
            } catch {
                await systemAudio.stop()
                throw error
            }
            self.systemAudio = systemAudio
            self.microphone = microphone
            currentFolder = callFolder
            state = .recording
            startDate = Date()
            elapsed = 0
            startTimer()
        } catch {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            state = .idle
            errorMessage = Self.describe(error)
        }
    }

    /// A track failed mid-call: stop both, keep what was recorded, and still transcribe it.
    private func captureFailed(_ error: Error) {
        guard currentFolder != nil else { return }
        errorMessage = Self.describe(error)
        Task { await stopRecording() }
    }

    // MARK: - Transcription

    private func enqueueTranscription(of folder: URL) {
        pendingTranscriptions.append(folder)
        guard !isTranscribing else { return }
        isTranscribing = true
        Task { await runTranscriptions() }
    }

    private func runTranscriptions() async {
        while !pendingTranscriptions.isEmpty {
            let folder = pendingTranscriptions.removeFirst()
            transcriptionPhase = .transcribing
            do {
                lastTranscriptURL = try await Transcriber.transcribe(folder: folder) { [weak self] phase in
                    guard let self, self.isTranscribing else { return }
                    self.transcriptionPhase = phase
                }
            } catch {
                errorMessage = "Transcription failed: \(error.localizedDescription)"
            }
        }
        transcriptionPhase = nil
        isTranscribing = false
    }

    private static func describe(_ phase: Transcriber.Phase) -> String {
        switch phase {
        case .downloadingModel(let fraction):
            fraction > 0 ? "Downloading model… \(Int(fraction * 100))%" : "Downloading model…"
        case .transcribing:
            "Transcribing…"
        }
    }

    /// The most recently written transcript.md in any call folder.
    private static func findLastTranscript() -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: nil)) ?? []
        return folders
            .map { $0.appending(path: Transcriber.transcriptName) }
            .compactMap { url -> (url: URL, date: Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, date)
            }
            .max { $0.date < $1.date }?
            .url
    }

    // MARK: - Helpers

    /// Creates ~/Documents/CallCaptures/<yyyy-MM-dd_HHmm>, adding a suffix if that minute is taken.
    private static func makeCallFolder() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let base = formatter.string(from: Date())

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        var folder = recordingsFolder.appending(path: base, directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
            folder = recordingsFolder.appending(path: "\(base)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? SCStreamError, error.code == .userDeclined {
            return "Screen & System Audio Recording permission denied"
        }
        return error.localizedDescription
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startDate = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(startDate)
            }
        }
        // .common keeps the timer firing while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startDate = nil
        elapsed = 0
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
