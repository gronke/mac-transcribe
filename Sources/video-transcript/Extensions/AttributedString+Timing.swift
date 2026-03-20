import CoreMedia
import Foundation
import NaturalLanguage
import Speech

extension SpeechTranscriber.Result {
    /// Splits this transcription result into sentence-level segments
    /// with timing proportionally derived from the result's time range.
    func sentenceSegments() -> [TranscriptionSegment] {
        let plainText = String(text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else { return [] }

        let startSeconds = CMTimeGetSeconds(range.start)
        let duration = CMTimeGetSeconds(range.duration)
        let endSeconds = startSeconds + duration

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = plainText

        var segments: [TranscriptionSegment] = []
        let totalChars = max(plainText.count, 1)

        tokenizer.enumerateTokens(in: plainText.startIndex..<plainText.endIndex) { tokenRange, _ in
            let sentence = String(plainText[tokenRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }

            let charStart = plainText.distance(from: plainText.startIndex, to: tokenRange.lowerBound)
            let charEnd = plainText.distance(from: plainText.startIndex, to: tokenRange.upperBound)

            let segStart = startSeconds + duration * Double(charStart) / Double(totalChars)
            let segEnd = startSeconds + duration * Double(charEnd) / Double(totalChars)

            segments.append(TranscriptionSegment(
                text: sentence,
                startTime: segStart,
                endTime: segEnd
            ))
            return true
        }

        return segments.isEmpty
            ? [TranscriptionSegment(text: plainText, startTime: startSeconds, endTime: endSeconds)]
            : segments
    }
}
