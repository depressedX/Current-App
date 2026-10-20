#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/current-diagnostics.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 "$ROOT/Current/Diagnostics/AppLog.swift" "$ROOT/Tests/DiagnosticsChecks.swift" -o "$CHECK_DIR/check-diagnostics"
"$CHECK_DIR/check-diagnostics"
