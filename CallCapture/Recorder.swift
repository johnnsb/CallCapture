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
@Observable
final class Recorder {
    enum State: Equatable {
        case idle
        case starting
        case recording
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var startDate: Date?
    private(set) var elapsed: TimeInterval = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var systemAudio: SystemAudioCapture?
    @ObservationIgnored private var microphone: MicrophoneCapture?

    static let recordingsFolder = URL.documentsDirectory.appending(path: "CallCaptures", directoryHint: .isDirectory)

    var isRecording: Bool { state == .recording }

    var statusText: String {
        switch state {
        case .idle: "Idle"
        case .starting: "Starting…"
        case .recording: "Recording \(Self.format(elapsed))"
        case .failed(let message): "Error: \(message)"
        }
    }

    func toggle() {
        switch state {
        case .recording: Task { await stopRecording() }
        case .starting: break
        case .idle, .failed: startRecording()
        }
    }

    func startRecording() {
        guard state != .starting, state != .recording else { return }
        state = .starting
        Task { await beginCapture() }
    }

    func stopRecording() async {
        stopTimer()
        if let microphone {
            self.microphone = nil
            microphone.stop()
        }
        if let systemAudio {
            self.systemAudio = nil
            await systemAudio.stop()
        }
        if state == .recording { state = .idle }
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    // MARK: - Private

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
            state = .recording
            startDate = Date()
            elapsed = 0
            startTimer()
        } catch {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            state = .failed(Self.describe(error))
        }
    }

    private func captureFailed(_ error: Error) {
        guard systemAudio != nil || microphone != nil else { return }
        Task { await stopRecording() }
        state = .failed(Self.describe(error))
    }

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
