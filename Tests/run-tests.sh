#!/bin/zsh
# SPDX-License-Identifier: MIT
set -euo pipefail
root="${0:A:h:h}"
stage=$(mktemp -d "${TMPDIR:-/tmp}/cfv-heic-tests.XXXXXX")
trap 'rm -rf "$stage"' EXIT
common=("$root/Sources/HotPixelCore.swift" "$root/Sources/ImpulseCleanup.swift")
function compile_and_run() {
  local name="$1"
  shift
  xcrun --sdk macosx swiftc -parse-as-library -O -target arm64-apple-macosx12.0 \
    -module-cache-path "$stage/modules" "${common[@]}" "$@" -o "$stage/$name"
}
compile_and_run core "$root/Tests/CoreTests.swift"
"$stage/core"
compile_and_run planner "$root/Sources/CalibrationPlanner.swift" "$root/Tests/PlannerTests.swift"
"$stage/planner" "$@"
compile_and_run clusters "$root/Sources/CalibrationPlanner.swift" "$root/Tests/ClusterTests.swift"
"$stage/clusters"
compile_and_run impulses "$root/Tests/ImpulseTests.swift"
"$stage/impulses"
compile_and_run automatic "$root/Sources/CalibrationPlanner.swift" "$root/Sources/HotPixelUI.swift" "$root/Tests/AutomaticCalibrationTests.swift"
"$stage/automatic" "$@"

compile_and_run lut "$root/Sources/ColorLUT.swift" "$root/Tests/LUTTests.swift"
"$stage/lut" "$root/Resources/LUTs" 36
