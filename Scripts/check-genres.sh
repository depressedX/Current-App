#!/bin/zsh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/Tools/PCGenreReference/.cache/native-check"
REFERENCE="${1:-$ROOT/Tools/PCGenreReference/.cache/reference}"
RUNTIME_CACHE="${CURRENT_SPM_CACHE:-/tmp/current-spm}"
python3 - "$ROOT" "$WORK" "$RUNTIME_CACHE" <<'PY'
from pathlib import Path
import sys,shutil
root,work,cache=map(Path,sys.argv[1:])
source=cache/'checkouts/onnxruntime-swift-package-manager/objectivec'
framework=cache/'artifacts/onnxruntime-swift-package-manager/onnxruntime/onnxruntime.xcframework'
if not source.is_dir() or not framework.is_dir():
 raise SystemExit('先使用 Xcode 解析 project.yml 指定的 ONNX Runtime 1.24.2 依赖，再设置 CURRENT_SPM_CACHE。')
(work/'Sources/Check').mkdir(parents=True,exist_ok=True)
for f in ['Current/Core/Models.swift','Current/Core/RecommendationQuery.swift','Current/Analysis/AnalysisModels.swift','Current/Analysis/LyricsModels.swift','Current/Analysis/SemanticModels.swift','Current/Analysis/AcousticDSP.swift','Current/Analysis/GenreFrontend.swift','Current/Analysis/GenreAnalyzer.swift','Current/Diagnostics/AppLog.swift','Tests/GenreChecks.swift']:
 shutil.copy2(root/f,work/'Sources/Check'/Path(f).name)
shutil.copytree(source,work/'Bindings',dirs_exist_ok=True)
link=work/'onnxruntime.xcframework'
if link.is_symlink():link.unlink()
if not link.exists():link.symlink_to(framework,target_is_directory=True)
(work/'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GenreCheck", platforms: [.macOS(.v14)], targets: [
.binaryTarget(name: "onnxruntime", path: "onnxruntime.xcframework"),
.target(name: "OnnxRuntimeBindings", dependencies: ["onnxruntime"], path: "Bindings",
exclude: ["ReadMe.md", "format_objc.sh", "test", "docs", "ort_checkpoint.mm", "ort_checkpoint_internal.h", "ort_training_session_internal.h", "ort_training_session.mm", "include/ort_checkpoint.h", "include/ort_training_session.h", "include/onnxruntime_training.h"], cxxSettings: [.define("SPM_BUILD")]),
.executableTarget(name: "Check", dependencies: ["OnnxRuntimeBindings"])
], cxxLanguageStandard: .cxx17)
''')
PY
CURRENT_DIAGNOSTICS_ROOT="$WORK/logs" swift run -c release --package-path "$WORK" Check \
 "$ROOT/Current/Resources/Semantics/Genres" "$REFERENCE"
