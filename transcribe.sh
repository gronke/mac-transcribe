#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Build in release mode if binary is missing or sources are newer
BINARY="$SCRIPT_DIR/.build/release/video-transcript"

if [ ! -f "$BINARY" ] || \
   [ -n "$(find "$SCRIPT_DIR/Sources" "$SCRIPT_DIR/Package.swift" -newer "$BINARY" 2>/dev/null)" ]; then
    echo "Building video-transcript..." >&2
    swift build -c release --package-path "$SCRIPT_DIR" 2>&1 | tail -1 >&2
fi

exec "$BINARY" "$@"
