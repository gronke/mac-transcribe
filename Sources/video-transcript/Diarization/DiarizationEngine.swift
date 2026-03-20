import FluidAudio
import Foundation

struct DiarizationEngine {
    let maxSpeakers: Int?

    /// Runs speaker diarization on an audio file via FluidAudio.
    /// The file is automatically resampled to 16 kHz internally.
    func diarize(wavURL: URL) async throws -> [SpeakerSegment] {
        var config = OfflineDiarizerConfig.default
        if let maxSpeakers {
            config = config.withSpeakers(max: maxSpeakers)
        }

        let manager = OfflineDiarizerManager(config: config)
        let result = try await manager.process(wavURL)

        return result.segments.map { segment in
            SpeakerSegment(
                speakerId: segment.speakerId,
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds)
            )
        }
    }
}
