@preconcurrency import AVFoundation
import Speech

/// Consumes a live audio stream via SpeechAnalyzer in streaming mode,
/// tags each segment with the current speaker, and publishes to a TranscriptStore.
struct LiveTranscriptionEngine {
    let locale: Locale
    let speakerProvider: @Sendable () async -> ActiveSpeaker?
    let store: TranscriptStore

    func run(audioStream: sending AsyncStream<AVAudioPCMBuffer>) async throws {
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            let supported = await SpeechTranscriber.supportedLocales
            throw TranscriptionError.localeNotSupported(locale, available: supported.map(\.identifier))
        }

        let transcriber = SpeechTranscriber(
            locale: resolved,
            preset: .timeIndexedTranscriptionWithAlternatives
        )

        // Map AVAudioPCMBuffer → AnalyzerInput for the streaming API
        let inputStream = audioStream.map { buffer in
            AnalyzerInput(buffer: buffer)
        }

        let analyzer = try await SpeechAnalyzer(
            inputSequence: inputStream,
            modules: [transcriber]
        )

        for try await result in transcriber.results {
            guard result.isFinal else { continue }

            var segments = result.sentenceSegments()
            let speaker = await speakerProvider()

            for i in segments.indices {
                segments[i].speaker = speaker?.name
            }

            for segment in segments {
                await store.append(segment)
            }
        }

        _ = analyzer
    }
}
