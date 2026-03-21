# video-transcript

CLI tool that transcribes video files with speaker identification, running entirely on-device. Also supports live transcription of BigBlueButton meetings.

## Quick start

### Transcribe a video file

```
./transcribe.sh <video-file> [--locale en-US] [--output-format txt|srt] [-o output-file] [--max-speakers N] [--no-diarization]
```

### Live-transcribe a BBB meeting

```
./bbb.sh <join-url> [--locale en-US] [--port 8080] [--output-format txt|srt] [-o transcript.txt]

# Or with shared secret (no browser link needed):
./bbb.sh --server https://bbb.example.com/bigbluebutton --secret XXXX --meeting-id abc123
```

While running, the live transcript is available as an SSE stream at `http://localhost:8080`.

## Building

### Prerequisites

- **macOS Tahoe (26)** on Apple Silicon
- **Swift 6.2+** (ships with Xcode 26)
- **On-device speech recognition** enabled in System Settings > Apple Intelligence & Siri

### Build from source

```bash
# 1. Resolve dependencies (downloads ~80 MB WebRTC XCFramework)
swift package resolve

# 2. Fix WebRTC framework headers for macOS (required once after resolve)
./scripts/fix-webrtc-macos.sh

# 3. Build
swift build -c release
```

The wrapper scripts (`transcribe.sh`, `bbb.sh`) handle this automatically — they rebuild when sources change.

### What `fix-webrtc-macos.sh` does

The `stasel/WebRTC` XCFramework ships with a broken macOS slice (missing individual ObjC headers, only the umbrella header). The script copies headers from the Mac Catalyst slice, removes iOS-only headers (`AVAudioSession`, `UIKit` dependencies), and creates the `sdk/objc/base/` directory structure needed by relative `#import` paths. Run it again if you update the WebRTC dependency version.

## Dependencies

### System frameworks

| Framework | Usage |
|-----------|-------|
| **Speech** (`SpeechAnalyzer`, `SpeechTranscriber`) | On-device transcription with word-level timing |
| **AVFoundation** (`AVAssetReader`, `AVAssetWriter`, `AVAudioConverter`) | Audio extraction and resampling |
| **NaturalLanguage** (`NLTokenizer`) | Sentence boundary detection for segment splitting |
| **CoreMedia** (`CMTimeRange`) | Timestamp representation |
| **CryptoKit** (`SHA256`) | BBB API checksum authentication |

### Swift packages

| Package | Source | Usage |
|---------|--------|-------|
| **[swift-argument-parser](https://github.com/apple/swift-argument-parser)** 1.5+ | Apple | CLI argument parsing |
| **[FluidAudio](https://github.com/FluidInference/FluidAudio)** (main) | FluidInference | On-device speaker diarization via CoreML/ANE |
| **[WebRTC](https://github.com/stasel/WebRTC)** 141+ | stasel | WebRTC peer connection for BBB audio reception |
| **[swift-nio](https://github.com/apple/swift-nio)** 2.65+ | Apple | SSE HTTP server (`NIOHTTP1`, `NIOCore`, `NIOPosix`) |

FluidAudio transitively pulls in:
- [swift-transformers](https://github.com/huggingface/swift-transformers) (Hugging Face)
- [swift-huggingface](https://github.com/huggingface/swift-huggingface) (model downloading)
- swift-collections, swift-crypto, swift-nio, swift-atomics, swift-system (Apple)

### Model assets (downloaded at runtime)

- **Speech recognition model** — managed by the OS via `AssetInventory`. Downloaded per-locale on first use.
- **Diarization models** — 5 CoreML models downloaded by FluidAudio from Hugging Face on first use. Cached in `~/Library/Application Support/FluidAudio/Models/`.

## Local BBB dev environment

A full BigBlueButton 3.0 stack for developing and testing the live-transcription plugin.

```bash
# First run — prompts for domain and Let's Encrypt email:
./dev/start.sh

# Stop:
./dev/stop.sh            # keep data
./dev/stop.sh --volumes  # wipe data
```

By default, HAProxy terminates TLS with self-signed certificates. To use an existing global [Traefik](https://github.com/schuhkarton/docker-traefik) reverse proxy instead (real Let's Encrypt certs, shared ports 80/443):

```bash
REVERSE_PROXY=traefik ./dev/start.sh
```

This requires the `proxy` Docker network and a running Traefik instance. See `dev/docker-compose.traefik.yml` for details.

## BBB browser plugin

A thin React plugin for BigBlueButton that displays the live transcript inside the BBB UI.

```bash
cd bbb-plugin
npm install
npm run build    # produces dist/plugin.js
```

Set `manifest.json`'s `javascriptEntrypointUrl` to where you host `plugin.js`, then add it to your BBB server's plugin manifests. The plugin connects to the SSE endpoint (default `http://localhost:8080`) and renders a scrolling transcript panel.