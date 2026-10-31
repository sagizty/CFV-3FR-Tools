#!/bin/zsh
# SPDX-License-Identifier: MIT
set -euo pipefail
root="${0:A:h:h}"
stage=$(mktemp -d "${TMPDIR:-/tmp}/cfv-heic-icon.XXXXXX")
trap 'rm -rf "$stage"' EXIT
xcrun --sdk macosx swiftc -module-cache-path "$stage/modules" "$root/scripts/make-icon.swift" -o "$stage/make-icon"
"$stage/make-icon" "$root/Resources/logo.png" "$stage/AppIcon.iconset"
iconutil -c icns "$stage/AppIcon.iconset" -o "$root/Resources/AppIcon.icns"
cp "$stage/AppIcon.iconset/icon_512x512@2x.png" "$root/Resources/icon.png"
print "Updated App icons from Resources/logo.png."
