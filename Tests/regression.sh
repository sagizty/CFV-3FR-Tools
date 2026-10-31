#!/bin/zsh
# SPDX-License-Identifier: MIT
set -euo pipefail
root="${0:A:h:h}"
source_raw="${1:?Pass the path to a real .3FR; the source will not be changed}"
if [[ ! -f "$source_raw" ]]; then
  print -u2 "Input RAW file not found: $source_raw"
  exit 2
fi
stage=$(mktemp -d "${TMPDIR:-/tmp}/cfv-heic-regression.XXXXXX")
trap 'rm -rf "$stage"' EXIT
python3 - "$root" "$stage" <<'PY'
from pathlib import Path
import sys
root,stage=map(Path,sys.argv[1:])
for name,source in [('baseline',root/'Tests/Fixtures/UnrepairedConverter.swift.txt'),('updated',root/'Sources/Conversion.swift')]:
    body=source.read_text().split('private func droppedFileURL')[0]
    body+='''
private let result=try Converter.convert(URL(fileURLWithPath:CommandLine.arguments[1]),to:URL(fileURLWithPath:CommandLine.arguments[2]),quality:0.92,useP3:true,trashOriginal:false)
print(result.width,result.height,result.outputBytes)
'''
    folder=stage/name;folder.mkdir()
    (folder/'main.swift').write_text(body)
PY
xcrun --sdk macosx swiftc -O -target arm64-apple-macosx12.0 -module-cache-path "$stage/modules" "$stage/baseline/main.swift" -o "$stage/baseline-convert"
xcrun --sdk macosx swiftc -O -target arm64-apple-macosx12.0 -module-cache-path "$stage/modules" \
  "$root/Sources/HotPixelCore.swift" "$root/Sources/ImpulseCleanup.swift" "$root/Sources/CalibrationPlanner.swift" "$root/Sources/ColorLUT.swift" \
  "$stage/updated/main.swift" -o "$stage/updated-convert"
"$stage/baseline-convert" "$source_raw" "$stage/before"
"$stage/updated-convert" "$source_raw" "$stage/after"
name="${source_raw:t:r}"
cmp "$stage/before/$name.heic" "$stage/after/$name.heic"
print "PASS: repair disabled produces byte-identical HEIC; source untouched."
