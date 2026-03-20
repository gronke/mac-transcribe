import Foundation

struct TranscriptMerger {
    /// Assigns a speaker to each transcription segment based on majority
    /// time overlap with diarization speaker segments.
    static func merge(
        transcription: [TranscriptionSegment],
        speakers: [SpeakerSegment]
    ) -> [TranscriptionSegment] {
        transcription.map { segment in
            var merged = segment
            merged.speaker = bestSpeaker(for: segment, from: speakers)
            return merged
        }
    }

    private static func bestSpeaker(
        for segment: TranscriptionSegment,
        from speakers: [SpeakerSegment]
    ) -> String? {
        var overlapBySpeaker: [String: TimeInterval] = [:]

        for speaker in speakers {
            let overlapStart = max(segment.startTime, speaker.startTime)
            let overlapEnd = min(segment.endTime, speaker.endTime)
            let overlap = overlapEnd - overlapStart

            if overlap > 0 {
                overlapBySpeaker[speaker.speakerId, default: 0] += overlap
            }
        }

        return overlapBySpeaker.max(by: { $0.value < $1.value })?.key
    }
}
