@preconcurrency import AVFoundation

struct AudioExtractor {
    /// Exports a 16 kHz mono WAV from a media file, suitable for transcription and diarization.
    static func exportWAV(from mediaURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: mediaURL)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioExtractionError.noAudioTrack
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw AudioExtractionError.readerCreationFailed
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        nonisolated(unsafe) let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack, outputSettings: outputSettings
        )
        reader.add(readerOutput)

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .wav) else {
            throw AudioExtractionError.writerCreationFailed
        }

        nonisolated(unsafe) let writerInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: outputSettings
        )
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio-export")) {
                while writerInput.isReadyForMoreMediaData {
                    if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sampleBuffer)
                    } else {
                        writerInput.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }

        await writer.finishWriting()

        guard writer.status == .completed else {
            throw AudioExtractionError.exportFailed(writer.error)
        }

        return outputURL
    }
}

enum AudioExtractionError: LocalizedError {
    case noAudioTrack
    case readerCreationFailed
    case writerCreationFailed
    case exportFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            "The video file contains no audio track."
        case .readerCreationFailed:
            "Failed to create asset reader."
        case .writerCreationFailed:
            "Failed to create asset writer."
        case .exportFailed(let error):
            "Audio export failed: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}
