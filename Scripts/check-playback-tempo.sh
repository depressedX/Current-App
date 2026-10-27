#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/current-playback-tempo.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 -module-cache-path "$CHECK_DIR/cache" \
  "$ROOT/Current/Core/PlaybackTempo.swift" "$ROOT/Tests/PlaybackTempoChecks.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
