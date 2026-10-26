#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/current-openrouter.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
mkdir -p "$CHECK_DIR/Sources/Checks"
cp "$ROOT/Current/Core/RecommendationQuery.swift" "$ROOT/Current/Core/OpenRouterClient.swift" \
   "$ROOT/Tests/OpenRouterChecks.swift" "$CHECK_DIR/Sources/Checks/"
cat > "$CHECK_DIR/Package.swift" <<'SWIFT'
// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "Checks", platforms: [.macOS(.v13)], dependencies: [
    .package(url: "https://github.com/MacPaw/OpenAI", exact: "0.5.3")
], targets: [.executableTarget(name: "Checks", dependencies: [.product(name: "OpenAI", package: "OpenAI")])])
SWIFT
swift run --package-path "$CHECK_DIR"
