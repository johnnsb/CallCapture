//
//  Recorder.swift
//  CallCapture
//

import Foundation
import Observation

/// Owns recording state. Every recording starts through `startRecording()`,
/// so a consent gate can later sit in front of that one call.
@Observable
final class Recorder {
    private(set) var isRecording = false
    private(set) var startDate: Date?
    private(set) var elapsed: TimeInterval = 0

    @ObservationIgnored private var timer: Timer?

    var statusText: String {
        isRecording ? "Recording \(Self.format(elapsed))" : "Idle"
    }

    func toggle() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        // Milestones 2–3: begin both capture streams (system audio + mic) here.
        isRecording = true
        startDate = Date()
        elapsed = 0
        startTimer()
    }

    func stopRecording() {
        guard isRecording else { return }
        // Milestones 2–3: stop both capture streams and finalize files here.
        timer?.invalidate()
        timer = nil
        isRecording = false
        startDate = nil
        elapsed = 0
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

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
