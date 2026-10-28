//
//  SystemAudioCapture.swift
//  CallCapture
//

import AVFoundation
import ScreenCaptureKit

/// Captures all system audio with ScreenCaptureKit and streams it to a WAV file
/// as it arrives, so a crash loses seconds rather than the whole call.
nonisolated final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .noDisplay: "No display available for audio capture"
            }
        }
    }

    static let sampleRate = 48_000
    static let channelCount = 2

    private let fileURL: URL
    private let onFailure: @MainActor @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "CallCapture.SystemAudioCapture")
    private var stream: SCStream?

    // Accessed only on `queue`.
    private var file: AVAudioFile?
    private var isFinished = false

    /// `onFailure` runs on the main actor if capture or writing fails mid-recording.
    init(fileURL: URL, onFailure: @escaping @MainActor @Sendable (Error) -> Void) {
        self.fileURL = fileURL
        self.onFailure = onFailure
    }

    func start() async throws {
        // Throws SCStreamError.userDeclined if Screen & System Audio Recording is denied.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(Self.sampleRate),
            channels: AVAudioChannelCount(Self.channelCount)
        )!
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
        queue.sync { self.file = file }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = Self.channelCount
        // Audio only: no screen output is added, and the video side is kept tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            queue.sync { closeFile() }
            throw error
        }
        self.stream = stream
    }

    func stop() async {
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        queue.sync { closeFile() }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !isFinished, let file, sampleBuffer.isValid else { return }
        do {
            guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
            try file.write(from: buffer)
        } catch {
            closeFile()
            report(error)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.closeFile() }
        report(error)
    }

    // MARK: - Private

    /// Must run on `queue`. Finalizes the WAV header; later buffers are ignored.
    private func closeFile() {
        isFinished = true
        file?.close()
        file = nil
    }

    private func report(_ error: Error) {
        let onFailure = onFailure
        Task { @MainActor in onFailure(error) }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
