#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/Tools/PCPrecompute/.cache/native-check"
mkdir -p "$WORK/Sources/Check"
# Copy only tested production sources, so the check cannot drift into a second implementation.
for FILE in Current/Core/Models.swift Current/Analysis/AnalysisModels.swift Current/Analysis/LyricsModels.swift \
 Current/Analysis/SemanticModels.swift Current/Analysis/AcousticDSP.swift \
 Current/Analysis/DCLAPFrontend.swift Current/Analysis/DCLAPAnalyzer.swift \
 Current/Diagnostics/AppLog.swift Tests/SemanticChecks.swift; do
 cp "$ROOT/$FILE" "$WORK/Sources/Check/"
done
cat > "$WORK/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "NativeSemanticCheck", platforms: [.macOS(.v14)],
 dependencies: [.package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2")],
 targets: [.executableTarget(name: "Check", dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")])])
EOF
CURRENT_DIAGNOSTICS_ROOT="$WORK/logs" swift run -c release --package-path "$WORK" Check \
 "$ROOT/Current/Resources/Semantics/concept-vectors.json" \
 "$ROOT/Tools/PCPrecompute/.cache" \
 "$ROOT/Current/Resources/Semantics/Models/model_epoch_36.onnx" "$@"
