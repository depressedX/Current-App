#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/current-core.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun swiftc -swift-version 5 \
  "$ROOT/Current/Core/Models.swift" \
  "$ROOT/Current/Core/KeychainStore.swift" \
  "$ROOT/Current/Core/NetEaseCrypto.swift" \
  "$ROOT/Current/Core/NetEaseAPI.swift" \
  "$ROOT/Tests/HostCoreChecks.swift" -o "$CHECK_DIR/check-core"
"$CHECK_DIR/check-core" "$@"
