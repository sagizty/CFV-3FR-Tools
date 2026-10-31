#!/bin/zsh
# SPDX-License-Identifier: MIT
set -euo pipefail
root="${0:A:h}"
output="${1:-${root}/dist}"
lut_resources="${2:-${root}/Resources/LUTs}"
if [[ -n "${2:-}" && ! -f "$lut_resources/catalog.json" ]]; then
  print -u2 "Missing LUT catalog.json"; exit 2
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${root}/Resources/Info.plist")
stage=$(mktemp -d "${TMPDIR:-/tmp}/cfv-heic-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="${stage}/CFV HEIC.app"
mkdir -p "${app}/Contents/MacOS" "${app}/Contents/Resources" "$output" "$stage/modules"
xcrun --sdk macosx swiftc -parse-as-library -O -target arm64-apple-macosx12.0 \
  -module-cache-path "$stage/modules" \
  "$root/Sources/App.swift" "$root/Sources/HotPixelCore.swift" \
  "$root/Sources/ImpulseCleanup.swift" "$root/Sources/CalibrationPlanner.swift" \
  "$root/Sources/HotPixelUI.swift" "$root/Sources/Conversion.swift" \
  "$root/Sources/ColorLUT.swift" -o "${app}/Contents/MacOS/CFVHEIC"
cp "$root/Resources/Info.plist" "${app}/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "${app}/Contents/Resources/AppIcon.icns"
cp "$root/docs/THIRD_PARTY_NOTICES.md" "${app}/Contents/Resources/THIRD_PARTY_NOTICES.md"
if [[ -f "$lut_resources/catalog.json" ]]; then
  ditto --norsrc --noextattr --noqtn --noacl "$lut_resources" "${app}/Contents/Resources/LUTs"
fi
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
archive="${output}/CFV-HEIC-${version}-macOS-arm64.zip"
ditto --norsrc --noextattr --noqtn --noacl -c -k --keepParent "$app" "$archive"
print "Built: $archive"
