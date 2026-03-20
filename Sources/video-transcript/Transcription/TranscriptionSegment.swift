import Foundation

struct TranscriptionSegment: Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    var speaker: String?
}
