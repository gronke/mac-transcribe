import Foundation

struct PlainTextFormatter {
    static func format(_ segments: [TranscriptionSegment]) -> String {
        segments.map { segment in
            let timestamp = formatTimestamp(segment.startTime)
            if let speaker = segment.speaker {
                return "\(speaker) [\(timestamp)]: \(segment.text)"
            } else {
                return "[\(timestamp)] \(segment.text)"
            }
        }.joined(separator: "\n")
    }

    static func formatTimestamp(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
