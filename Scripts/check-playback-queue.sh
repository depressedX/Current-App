#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/current-playback-queue.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 \
  "$ROOT/Current/Diagnostics/AppLog.swift" \
  "$ROOT/Current/Core/Models.swift" \
  "$ROOT/Current/Companion/CompanionProtocol.swift" \
  "$ROOT/Current/Core/RecommendationQuery.swift" \
  "$ROOT/Current/Core/OpenRouterClient.swift" \
  "$ROOT/Current/Core/KeychainStore.swift" \
  "$ROOT/Current/Core/NetEaseCrypto.swift" \
  "$ROOT/Current/Core/NetEaseAPI.swift" \
  "$ROOT/Current/Core/AppStore.swift" \
  "$ROOT"/Current/Analysis/*.swift \
  "$ROOT/Tests/PlaybackQueueChecks.swift" -o "$CHECK_DIR/check"
CURRENT_DIAGNOSTICS_ROOT="$CHECK_DIR/logs" "$CHECK_DIR/check"
