@preconcurrency import AVFoundation

/// Reads raw s16le PCM audio (16 kHz mono) from a FileHandle (typically a pipe
/// from bbb-audio's stdout) and yields AVAudioPCMBuffer (float32, 16 kHz, mono)
/// into an AsyncStream for consumption by SpeechAnalyzer.
final class AudioBufferAdapter: @unchecked Sendable {
    let stream: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation

    private let inputHandle: FileHandle
    private var readTask: Task<Void, Never>?

    /// Output format expected by SpeechAnalyzer: 16 kHz, float32, mono.
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    init(inputHandle: FileHandle = .standardInput) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.stream = stream
        self.continuation = continuation
        self.inputHandle = inputHandle
    }

    /// Begin reading PCM from the input handle in a background task.
    func start() {
        let handle = inputHandle
        let fmt = outputFormat
        let cont = continuation

        readTask = Task {
            var buffer = Data()
            // 320 samples * 2 bytes (s16le) = 640 bytes = 20 ms at 16 kHz
            let frameBytes = 640

            while !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break } // EOF — pipe closed

                buffer.append(data)

                while buffer.count >= frameBytes {
                    let frameData = buffer.prefix(frameBytes)
                    let sampleCount = frameData.count / 2

                    guard let pcmBuffer = AVAudioPCMBuffer(
                        pcmFormat: fmt,
                        frameCapacity: AVAudioFrameCount(sampleCount)
                    ) else { break }
                    pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

                    // Convert s16le integers to float32 [-1.0, 1.0)
                    frameData.withUnsafeBytes { raw in
                        let int16s = raw.bindMemory(to: Int16.self)
                        if let floats = pcmBuffer.floatChannelData?[0] {
                            for i in 0..<sampleCount {
                                floats[i] = Float(int16s[i]) / 32768.0
                            }
                        }
                    }

                    cont.yield(pcmBuffer)
                    buffer.removeFirst(frameBytes)
                }
            }

            cont.finish()
        }
    }

    /// Signal that the audio source has ended.
    func finish() {
        readTask?.cancel()
        continuation.finish()
    }
}
