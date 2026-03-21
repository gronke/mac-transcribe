import ArgumentParser

@main
struct VideoTranscript: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "video-transcript",
        abstract: "Transcribe video files with speaker identification.",
        subcommands: [Transcribe.self, LiveBBB.self],
        defaultSubcommand: Transcribe.self
    )
}
