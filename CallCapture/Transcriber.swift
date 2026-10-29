//
//  Transcriber.swift
//  CallCapture
//

import Foundation
import WhisperKit

/// Transcribes a call folder's me.wav and them.wav locally with WhisperKit and
/// merges them by timestamp into transcript.md. The audio files are only read.
nonisolated enum Transcriber {
    enum Phase: Sendable {
        case downloadingModel(fraction: Double)
        case transcribing
    }

    /// Whisper large-v3 turbo, quantized to ~626 MB: WhisperKit's recommended default on Apple Silicon Macs.
    static let modelVariant = "openai_whisper-large-v3-v20240930_626MB"
    static let modelsFolder = URL.applicationSupportDirectory.appending(path: "CallCapture/Models", directoryHint: .isDirectory)
    static let transcriptName = "transcript.md"

    private struct Line {
        let start: Float
        let speaker: String
        let text: String
    }

    /// Runs off the main actor. Returns the URL of the written transcript.
    @concurrent
    static func transcribe(
        folder: URL,
        onPhase: @escaping @MainActor @Sendable (Phase) -> Void
    ) async throws -> URL {
        let modelFolder = try await prepareModel(onPhase: onPhase)
        await onPhase(.transcribing)

        let whisper = try await WhisperKit(WhisperKitConfig(
            modelFolder: modelFolder.path(percentEncoded: false),
            verbose: false,
            logLevel: .none,
            load: true,
            download: false
        ))
        let options = DecodingOptions(
            language: "en",
            skipSpecialTokens: true,
            chunkingStrategy: .vad
        )

        // Each track on its own, then merged by start time.
        var lines: [Line] = []
        for (file, speaker) in [("me.wav", "Me"), ("them.wav", "Them")] {
            let url = folder.appending(path: file)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            let results = try await whisper.transcribe(audioPath: url.path(percentEncoded: false), decodeOptions: options)
            for segment in results.flatMap(\.segments) {
                guard let text = cleanedText(segment) else { continue }
                lines.append(Line(start: segment.start, speaker: speaker, text: text))
            }
        }
        lines.sort { $0.start < $1.start }

        var transcript = "# Call transcript: \(folder.lastPathComponent)\n\n"
        if lines.isEmpty {
            transcript += "_No speech detected._\n"
        }
        for line in lines {
            transcript += "[\(timestamp(line.start))] \(line.speaker): \(line.text)\n\n"
        }
        let transcriptURL = folder.appending(path: transcriptName)
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        return transcriptURL
    }

    /// Returns the downloaded model folder, downloading it the first time.
    private static func prepareModel(onPhase: @escaping @MainActor @Sendable (Phase) -> Void) async throws -> URL {
        let fileManager = FileManager.default
        // Written only after a complete download, so an interrupted one is retried.
        let marker = modelsFolder.appending(path: "\(modelVariant).ready")
        if let path = try? String(contentsOf: marker, encoding: .utf8),
           fileManager.fileExists(atPath: path) {
            return URL(filePath: path, directoryHint: .isDirectory)
        }

        try fileManager.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        await onPhase(.downloadingModel(fraction: 0))
        let folder = try await WhisperKit.download(variant: modelVariant, downloadBase: modelsFolder) { progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in onPhase(.downloadingModel(fraction: fraction)) }
        }
        try folder.path(percentEncoded: false).write(to: marker, atomically: true, encoding: .utf8)
        return folder
    }

    /// Drops empty, silent, and non-speech segments such as "[BLANK_AUDIO]" or "(music)".
    private static func cleanedText(_ segment: TranscriptionSegment) -> String? {
        // Whisper's own rule for segments that are most likely silence.
        if segment.noSpeechProb > 0.6, segment.avgLogprob < -1 { return nil }
        let text = segment.text
            .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let nonSpeech = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#, with: "", options: .regularExpression)
        guard nonSpeech.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return text
    }

    private static func timestamp(_ seconds: Float) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
