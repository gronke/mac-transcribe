#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build Rust binary if missing or sources are newer
RUST_BINARY="$SCRIPT_DIR/bbb-audio/target/release/bbb-audio"

if [ ! -f "$RUST_BINARY" ] || \
   [ -n "$(find "$SCRIPT_DIR/bbb-audio/src" "$SCRIPT_DIR/bbb-audio/Cargo.toml" -newer "$RUST_BINARY" 2>/dev/null)" ]; then
    echo "Building bbb-audio..." >&2
    cargo build --release --manifest-path "$SCRIPT_DIR/bbb-audio/Cargo.toml" 2>&1 | tail -1 >&2
fi

# Build Swift binary if missing or sources are newer
SWIFT_BINARY="$SCRIPT_DIR/.build/release/video-transcript"

if [ ! -f "$SWIFT_BINARY" ] || \
   [ -n "$(find "$SCRIPT_DIR/Sources" "$SCRIPT_DIR/Package.swift" -newer "$SWIFT_BINARY" 2>/dev/null)" ]; then
    echo "Building video-transcript..." >&2
    swift build -c release --package-path "$SCRIPT_DIR" 2>&1 | tail -1 >&2
fi

exec "$SWIFT_BINARY" bbb --bbb-audio-path "$RUST_BINARY" "$@"
