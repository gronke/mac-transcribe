import Foundation

struct TranscriptionSegment: Sendable, Codable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    var speaker: String?
}
