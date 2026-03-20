@preconcurrency import AVFoundation
import Speech

struct TranscriptionEngine {
    let locale: Locale

    /// Ensures speech model assets are downloaded and installed for the configured locale.
    /// Call before `transcribe` to avoid cascading failures in concurrent pipelines.
    func ensureModelAvailable() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }

        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            let supported = await SpeechTranscriber.supportedLocales
            throw TranscriptionError.localeNotSupported(
                locale,
                available: supported.map(\.identifier)
            )
        }

        let transcriber = SpeechTranscriber(
            locale: resolved,
            preset: .transcription
        )
        let status = await AssetInventory.status(forModules: [transcriber])

        switch status {
        case .installed:
            return
        case .supported, .downloading:
            fputs("Downloading speech model for \(resolved.identifier)...\n", stderr)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        case .unsupported:
            // Locale resolved but assets unavailable — might need to be enabled in
            // System Settings > Apple Intelligence & Siri > Language & Region.
            let installed = await SpeechTranscriber.installedLocales
            throw TranscriptionError.modelUnavailable(
                locale,
                installed: installed.map(\.identifier)
            )
        @unknown default:
            break
        }
    }

    /// Transcribes the given audio file using SpeechAnalyzer with a SpeechTranscriber module.
    /// Returns sentence-level segments with timing information.
    func transcribe(fileURL: URL) async throws -> [TranscriptionSegment] {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )

        let audioFile = try AVAudioFile(forReading: fileURL)
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile,
            modules: [transcriber],
            finishAfterFile: true
        )

        var segments: [TranscriptionSegment] = []
        for try await result in transcriber.results {
            guard result.isFinal else { continue }
            segments.append(contentsOf: result.sentenceSegments())
        }

        _ = analyzer // prevent premature deallocation
        return segments
    }
}

enum TranscriptionError: LocalizedError {
    case unavailable
    case localeNotSupported(Locale, available: [String])
    case modelUnavailable(Locale, installed: [String])

    var errorDescription: String? {
        switch self {
        case .unavailable:
            """
            Speech recognition is not available on this system. \
            Ensure on-device speech recognition is enabled in \
            System Settings > Apple Intelligence & Siri.
            """
        case .localeNotSupported(let locale, let available):
            if available.isEmpty {
                """
                Locale '\(locale.identifier)' is not supported and no locales are available. \
                Enable on-device speech recognition in \
                System Settings > Apple Intelligence & Siri.
                """
            } else {
                "Locale '\(locale.identifier)' is not supported. Supported: \(available.joined(separator: ", "))"
            }
        case .modelUnavailable(let locale, let installed):
            if installed.isEmpty {
                """
                No speech models are installed. Download a language in \
                System Settings > Apple Intelligence & Siri > Language & Region.
                """
            } else {
                """
                Model for '\(locale.identifier)' is not installed. \
                Installed: \(installed.joined(separator: ", ")). \
                Download more in System Settings > Apple Intelligence & Siri > Language & Region.
                """
            }
        }
    }
}
