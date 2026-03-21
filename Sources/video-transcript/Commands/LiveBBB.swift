import ArgumentParser
import Foundation

struct LiveBBB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bbb",
        abstract: "Live-transcribe a BigBlueButton meeting."
    )

    // MARK: - Arguments & options

    @Argument(help: "BBB join URL. Omit if using --server/--secret/--meeting-id.")
    var joinURL: String?

    @Option(name: .long, help: "BBB server URL (e.g. https://bbb.example.com/bigbluebutton).")
    var server: String?

    @Option(name: .long, help: "BBB shared secret for API authentication.")
    var secret: String?

    @Option(name: .long, help: "BBB meeting ID (used with --server and --secret).")
    var meetingId: String?

    @Option(name: .long, help: "Locale for transcription (e.g. en-US).")
    var locale: String = "en-US"

    @Option(name: .long, help: "SSE server port.")
    var port: Int = 8080

    @Option(name: .long, help: "Output format: txt or srt.")
    var outputFormat: OutputFormat = .txt

    @Option(name: .shortAndLong, help: "Output file path for transcript.")
    var output: String?

    @Option(name: .long, help: "Path to bbb-audio binary. Auto-detected if omitted.")
    var bbbAudioPath: String?

    // MARK: - Validation

    func validate() throws {
        if joinURL == nil && (server == nil || secret == nil || meetingId == nil) {
            throw ValidationError(
                "Provide either a join URL or all of --server, --secret, and --meeting-id."
            )
        }
    }

    // MARK: - Execution

    func run() async throws {
        let transcriptionLocale = Locale(identifier: locale)

        // 1. Ensure speech model is available
        fputs("Checking speech model...\n", stderr)
        let engine = TranscriptionEngine(locale: transcriptionLocale)
        try await engine.ensureModelAvailable()

        // 2. Start SSE server
        let store = TranscriptStore(outputPath: output, outputFormat: outputFormat)
        let sseServer = SSEServer(store: store, port: port)
        try await sseServer.start()

        // 3. Spawn bbb-audio process
        let bbbAudio = findBBBAudio()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bbbAudio)
        process.arguments = buildBBBAudioArgs()

        let audioPipe = Pipe()   // stdout: raw s16le PCM
        let eventPipe = Pipe()   // stderr: JSON events + log messages
        process.standardOutput = audioPipe
        process.standardError = eventPipe

        try process.run()
        fputs("bbb-audio started (PID: \(process.processIdentifier))\n", stderr)

        // 4. Track current speaker via stderr JSON events
        let tracker = SpeakerTracker()

        let eventTask = Task {
            let handle = eventPipe.fileHandleForReading
            var lineBuffer = ""

            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }

                guard let text = String(data: data, encoding: .utf8) else { continue }
                lineBuffer += text

                while let newline = lineBuffer.firstIndex(of: "\n") {
                    let line = String(lineBuffer[lineBuffer.startIndex..<newline])
                    lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
                    guard !line.isEmpty else { continue }
                    await Self.processEventLine(line, tracker: tracker)
                }
            }
        }

        // 5. Read PCM audio from bbb-audio stdout
        let audioAdapter = AudioBufferAdapter(
            inputHandle: audioPipe.fileHandleForReading
        )
        audioAdapter.start()

        // 6. Run live transcription
        let liveEngine = LiveTranscriptionEngine(
            locale: transcriptionLocale,
            speakerProvider: { await tracker.current },
            store: store
        )

        // 7. Handle SIGINT for graceful shutdown
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        signal(SIGINT, SIG_IGN)

        let shutdownTask = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                signalSource.setEventHandler {
                    continuation.resume()
                }
                signalSource.resume()
            }
        }

        // Race between transcription, process exit, and SIGINT
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await liveEngine.run(audioStream: audioAdapter.stream)
            }

            group.addTask {
                await shutdownTask.value
                throw CancellationError()
            }

            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().async {
                        process.waitUntilExit()
                        continuation.resume()
                    }
                }
                throw CancellationError()
            }

            do {
                try await group.next()
            } catch {
                // Expected — shutdown signal, process exit, or stream ended
            }
            group.cancelAll()
        }

        // 8. Cleanup
        fputs("\nShutting down...\n", stderr)
        signalSource.cancel()
        eventTask.cancel()
        audioAdapter.finish()
        if process.isRunning { process.terminate() }
        await store.finalize()
        await sseServer.stop()

        if let outputPath = output {
            fputs("Transcript written to \(outputPath)\n", stderr)
        }
    }

    // MARK: - Event parsing

    private static func processEventLine(_ line: String, tracker: SpeakerTracker) async {
        guard line.hasPrefix("{"),
              let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Not a JSON event — forward bbb-audio log output
            fputs("  [bbb-audio] \(line)\n", stderr)
            return
        }

        switch event["event"] as? String {
        case "speaker":
            if let name = event["name"] as? String,
               let userId = event["userId"] as? String {
                await tracker.update(ActiveSpeaker(userId: userId, name: name))
            } else {
                await tracker.update(nil)
            }

        case "meeting_info":
            if let meetingId = event["meetingId"] as? String,
               let voiceConf = event["voiceConf"] as? String {
                fputs("Joined meeting: \(meetingId) (voice: \(voiceConf))\n", stderr)
            }

        case "ended":
            fputs("Meeting ended.\n", stderr)

        default:
            break
        }
    }

    // MARK: - Binary discovery

    private func findBBBAudio() -> String {
        if let path = bbbAudioPath { return path }

        // Same directory as the video-transcript binary
        let selfDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().path
        let candidates = [
            "\(selfDir)/bbb-audio",
            "./bbb-audio/target/release/bbb-audio",
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return "bbb-audio" // assume on PATH
    }

    private func buildBBBAudioArgs() -> [String] {
        var args: [String] = []
        if let url = joinURL {
            args.append(url)
        } else if let server, let secret, let meetingId {
            args += ["--server", server, "--secret", secret, "--meeting-id", meetingId]
        }
        return args
    }
}

// MARK: - Speaker tracking actor

private actor SpeakerTracker {
    var current: ActiveSpeaker?

    func update(_ speaker: ActiveSpeaker?) {
        current = speaker
    }
}
