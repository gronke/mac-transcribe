# video-transcript

CLI tool that transcribes video files with speaker identification, running entirely on-device.

```
./transcribe.sh <video-file> [--locale en-US] [--output-format txt|srt] [-o output-file] [--max-speakers N] [--no-diarization]
```

## Dependencies

### System requirements

- **macOS Tahoe (26)** on Apple Silicon
- **Swift 6.2+**
- **On-device speech recognition** enabled in System Settings > Apple Intelligence & Siri (models download on first use)

### System frameworks

| Framework | Usage |
|-----------|-------|
| **Speech** (`SpeechAnalyzer`, `SpeechTranscriber`) | On-device transcription with word-level timing |
| **AVFoundation** (`AVAssetReader`, `AVAssetWriter`) | Audio extraction from video/audio containers |
| **NaturalLanguage** (`NLTokenizer`) | Sentence boundary detection for segment splitting |
| **CoreMedia** (`CMTimeRange`) | Timestamp representation |

### Swift packages

| Package | Source | Usage |
|---------|--------|-------|
| **[swift-argument-parser](https://github.com/apple/swift-argument-parser)** 1.5+ | Apple | CLI argument parsing |
| **[FluidAudio](https://github.com/FluidInference/FluidAudio)** (main) | FluidInference | On-device speaker diarization via CoreML/ANE |

FluidAudio transitively pulls in:
- [swift-transformers](https://github.com/huggingface/swift-transformers) (Hugging Face)
- [swift-huggingface](https://github.com/huggingface/swift-huggingface) (model downloading)
- swift-collections, swift-crypto, swift-nio, swift-atomics, swift-system (Apple)

### Model assets (downloaded at runtime)

- **Speech recognition model** — managed by the OS via `AssetInventory`. Downloaded per-locale on first use.
- **Diarization models** — 5 CoreML models downloaded by FluidAudio from Hugging Face on first use. Cached in `~/Library/Application Support/FluidAudio/Models/`.
