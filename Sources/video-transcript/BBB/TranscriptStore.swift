import Foundation

/// Thread-safe store for live transcript segments.
/// Fans out new segments to SSE subscribers and optionally appends to a file on disk.
actor TranscriptStore {
    private var segments: [TranscriptionSegment] = []
    private var subscribers: [UUID: AsyncStream<TranscriptionSegment>.Continuation] = [:]
    private var fileHandle: FileHandle?
    private let outputFormat: OutputFormat

    init(outputPath: String?, outputFormat: OutputFormat) {
        self.outputFormat = outputFormat

        if let path = outputPath {
            FileManager.default.createFile(atPath: path, contents: nil)
            self.fileHandle = FileHandle(forWritingAtPath: path)
        }
    }

    func append(_ segment: TranscriptionSegment) {
        segments.append(segment)

        for (_, continuation) in subscribers {
            continuation.yield(segment)
        }

        appendToDisk(segment)
    }

    func allSegments() -> [TranscriptionSegment] {
        segments
    }

    /// Creates a new subscriber stream that backfills existing segments
    /// then receives new ones in real-time.
    func subscribe() -> (id: UUID, stream: AsyncStream<TranscriptionSegment>) {
        let id = UUID()
        let existing = self.segments
        let (stream, continuation) = AsyncStream.makeStream(of: TranscriptionSegment.self)

        for segment in existing {
            continuation.yield(segment)
        }

        subscribers[id] = continuation
        return (id, stream)
    }

    func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    func finalize() {
        for (_, continuation) in subscribers {
            continuation.finish()
        }
        subscribers.removeAll()
        fileHandle?.closeFile()
        fileHandle = nil
    }

    // MARK: - Private

    private func appendToDisk(_ segment: TranscriptionSegment) {
        guard let fileHandle else { return }

        let line: String
        switch outputFormat {
        case .txt:
            let timestamp = PlainTextFormatter.formatTimestamp(segment.startTime)
            if let speaker = segment.speaker {
                line = "\(speaker) [\(timestamp)]: \(segment.text)\n"
            } else {
                line = "[\(timestamp)] \(segment.text)\n"
            }
        case .srt:
            let index = segments.count
            let start = SRTFormatter.srtTimestamp(segment.startTime)
            let end = SRTFormatter.srtTimestamp(segment.endTime)
            let text = segment.speaker.map { "[\($0)] \(segment.text)" } ?? segment.text
            line = "\(index)\n\(start) --> \(end)\n\(text)\n\n"
        }

        if let data = line.data(using: .utf8) {
            fileHandle.write(data)
        }
    }
}
