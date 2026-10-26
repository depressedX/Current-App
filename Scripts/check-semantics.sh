#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/current-semantic.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -O -swift-version 5 "$ROOT/Current/Core/Models.swift" "$ROOT/Current/Core/RecommendationQuery.swift" "$ROOT/Current/Analysis/AnalysisModels.swift" "$ROOT/Current/Analysis/LyricsModels.swift" "$ROOT/Current/Analysis/SemanticModels.swift" \
 "$ROOT/Current/Analysis/DCLAPFrontend.swift" "$ROOT/Current/Analysis/DCLAPAnalyzer.swift" \
 "$ROOT/Current/Analysis/AcousticDSP.swift" "$ROOT/Current/Diagnostics/AppLog.swift" \
 "$ROOT/Tests/SemanticChecks.swift" -o "$CHECK_DIR/check"
CURRENT_DIAGNOSTICS_ROOT="$CHECK_DIR/logs" "$CHECK_DIR/check" \
 "$ROOT/Current/Resources/Semantics/concept-vectors.json" "$@"
