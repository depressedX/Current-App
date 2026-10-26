#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/current-analysis.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -O -g -swift-version 5 \
  "$ROOT/Current/Diagnostics/AppLog.swift" \
  "$ROOT/Current/Core/Models.swift" \
  "$ROOT/Current/Companion/CompanionProtocol.swift" \
  "$ROOT/Current/Core/RecommendationQuery.swift" \
  "$ROOT/Current/Core/OpenRouterClient.swift" \
  "$ROOT/Current/Core/KeychainStore.swift" \
  "$ROOT/Current/Core/NetEaseCrypto.swift" \
  "$ROOT/Current/Core/NetEaseAPI.swift" \
  "$ROOT/Current/Analysis/SemanticModels.swift" \
  "$ROOT/Current/Analysis/AnalysisModels.swift" \
  "$ROOT/Current/Analysis/LyricsModels.swift" \
  "$ROOT/Current/Analysis/BGEWordPiece.swift" \
  "$ROOT/Current/Analysis/LyricsAnalyzer.swift" \
  "$ROOT/Current/Analysis/AcousticDSP.swift" \
  "$ROOT/Current/Analysis/NativeSongAnalyzer.swift" \
  "$ROOT/Current/Analysis/SongPoolStore.swift" \
  "$ROOT/Tests/AnalysisChecks.swift" -o "$CHECK_DIR/check-analysis"
CURRENT_DIAGNOSTICS_ROOT="$CHECK_DIR/logs" "$CHECK_DIR/check-analysis" "$@"
