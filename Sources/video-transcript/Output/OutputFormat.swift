import ArgumentParser

enum OutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
    case txt
    case srt
}
