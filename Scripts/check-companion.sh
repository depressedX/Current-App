#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/current-companion.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
# Build the production SRP package graph once; incremental reruns reuse this directory.
PAIR_BUILD="${CURRENT_COMPANION_BUILD:-/tmp/current-companion-build}"
xcodebuild -project "$ROOT/Current.xcodeproj" -scheme CurrentCompanion -configuration Debug \
  -clonedSourcePackagesDirPath "${CURRENT_COMPANION_PACKAGES:-$PAIR_BUILD/SourcePackages}" \
  -destination 'platform=macOS' -derivedDataPath "$PAIR_BUILD" CODE_SIGNING_ALLOWED=NO build > "$CHECK_DIR/build.log" 2>&1 || { cat "$CHECK_DIR/build.log"; exit 1; }
PRODUCTS="$PAIR_BUILD/Build/Products/Debug"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
  -I "$PRODUCTS" \
  -Xcc "-fmodule-map-file=$PAIR_BUILD/Build/Intermediates.noindex/GeneratedModuleMaps/CBigNumBoringSSL.modulemap" \
  "$PRODUCTS/SRP.o" "$PRODUCTS/BigNum.o" "$PRODUCTS/CBigNumBoringSSL.o" "$PRODUCTS/Crypto.o" \
  "$ROOT/Current/Diagnostics/AppLog.swift" \
  "$ROOT/Current/Core/Models.swift" \
  "$ROOT/Current/Core/RecommendationQuery.swift" \
  "$ROOT/Current/Core/NetEaseAPI.swift" \
  "$ROOT/Current/Core/NetEaseCrypto.swift" \
  "$ROOT/Current/Core/KeychainStore.swift" \
  "$ROOT"/Current/Analysis/*.swift \
  "$ROOT/Current/Companion/CompanionProtocol.swift" \
  "$ROOT/Current/Companion/CompanionConnection.swift" \
  "$ROOT/Current/Companion/CompanionClient.swift" \
  "$ROOT/MacCompanion/CompanionWorker.swift" \
  "$ROOT/Tests/CompanionChecks.swift" -o "$CHECK_DIR/check"
CURRENT_DIAGNOSTICS_ROOT="$CHECK_DIR/logs" "$CHECK_DIR/check" "$ROOT/Current/Resources/Semantics"
