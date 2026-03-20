import ArgumentParser
import Foundation

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe a video file with optional speaker identification."
    )

    @Argument(help: "Path to the video file.")
    var videoFile: String

    @Option(name: .long, help: "Locale for transcription (e.g. en-US).")
    var locale: String = "en-US"

    @Option(name: .long, help: "Output format: txt or srt.")
    var outputFormat: OutputFormat = .txt

    @Option(name: .shortAndLong, help: "Output file path. Prints to stdout if omitted.")
    var output: String?

    @Option(name: .long, help: "Maximum number of speakers for diarization.")
    var maxSpeakers: Int?

    @Flag(name: .long, help: "Skip speaker diarization.")
    var noDiarization: Bool = false

    func run() async throws {
        let videoURL = URL(fileURLWithPath: videoFile)

        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw TranscribeError.fileNotFound(videoFile)
        }

        let engine = TranscriptionEngine(locale: Locale(identifier: locale))

        // Ensure speech model is available before extracting audio or starting diarization,
        // so a missing model doesn't cascade-cancel the diarization task.
        try await engine.ensureModelAvailable()

        fputs("Extracting audio...\n", stderr)
        let audioURL = try await AudioExtractor.exportWAV(from: videoURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let segments: [TranscriptionSegment]

        if noDiarization {
            fputs("Transcribing...\n", stderr)
            segments = try await engine.transcribe(fileURL: audioURL)
        } else {
            fputs("Running transcription and diarization...\n", stderr)
            let diarizer = DiarizationEngine(maxSpeakers: maxSpeakers)

            async let transcription = engine.transcribe(fileURL: audioURL)
            async let speakers = diarizer.diarize(wavURL: audioURL)

            segments = try await TranscriptMerger.merge(
                transcription: transcription,
                speakers: speakers
            )
        }

        guard !segments.isEmpty else {
            throw TranscribeError.noSpeechDetected
        }

        let formatted = switch outputFormat {
        case .txt: PlainTextFormatter.format(segments)
        case .srt: SRTFormatter.format(segments)
        }

        if let outputPath = output {
            try formatted.write(toFile: outputPath, atomically: true, encoding: .utf8)
            fputs("Transcript written to \(outputPath)\n", stderr)
        } else {
            print(formatted)
        }
    }
}

enum TranscribeError: LocalizedError {
    case fileNotFound(String)
    case noSpeechDetected

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            "File not found: \(path)"
        case .noSpeechDetected:
            "No speech detected in the file."
        }
    }
}
