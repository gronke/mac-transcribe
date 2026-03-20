import Foundation

struct SRTFormatter {
    static func format(_ segments: [TranscriptionSegment]) -> String {
        segments.enumerated().map { index, segment in
            let sequence = index + 1
            let start = srtTimestamp(segment.startTime)
            let end = srtTimestamp(segment.endTime)
            let text = if let speaker = segment.speaker {
                "[\(speaker)] \(segment.text)"
            } else {
                segment.text
            }
            return "\(sequence)\n\(start) --> \(end)\n\(text)"
        }.joined(separator: "\n\n")
    }

    private static func srtTimestamp(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
}
