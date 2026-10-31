#!/bin/zsh
# SPDX-License-Identifier: MIT
set -euo pipefail
root="${0:A:h:h}"
source_raw="${1:?Pass a real 3FR}"
lut_resources="${2:?Pass a private LUT resources directory}"
[[ -f "$source_raw" && -f "$lut_resources/catalog.json" ]] || exit 2
stage=$(mktemp -d "${TMPDIR:-/tmp}/cfv-lut-integration.XXXXXX")
trap 'rm -rf "$stage"' EXIT
xcrun --sdk macosx swiftc -parse-as-library -O -target arm64-apple-macosx12.0 -module-cache-path "$stage/modules" \
 "$root/Sources/HotPixelCore.swift" "$root/Sources/ImpulseCleanup.swift" \
 "$root/Sources/CalibrationPlanner.swift" "$root/Sources/ColorLUT.swift" \
 "$root/Sources/Conversion.swift" "$root/Tests/LUTConversionTests.swift" -o "$stage/test"
"$stage/test" "$@"
