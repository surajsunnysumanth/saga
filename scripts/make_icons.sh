#!/bin/bash
# Build Resources/AppIcon.icns from Resources/AppIcon.png.
#
# The PNG is the master: it is traced from the owner's reference, so it is committed rather
# than generated at build time.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
[ -f Resources/AppIcon.png ] || { echo "Resources/AppIcon.png is missing" >&2; exit 1; }
iconset=$(mktemp -d "$PWD/build/icon.XXXXXX")
trap 'rm -rf "$iconset"' EXIT
mkdir "$iconset/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Resources/AppIcon.png --out "$iconset/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset/AppIcon.iconset" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
