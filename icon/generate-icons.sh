#!/usr/bin/env bash
# Render icon/tape.svg into AppIcon.icns and the asset catalog's AppIcon.appiconset.
# Requires: rsvg-convert (brew install librsvg), iconutil (built in).
set -euo pipefail
cd "$(dirname "$0")"

SVG="tape.svg"
ICONSET="$(mktemp -d)/AppIcon.iconset"
APPICONSET="../Resources/Assets.xcassets/AppIcon.appiconset"
OUT="AppIcon.icns"
mkdir -p "$ICONSET" "$APPICONSET"

emit() { # emit <name> <pixels>
  rsvg-convert -w "$2" -h "$2" "$SVG" -o "$ICONSET/$1"
  cp "$ICONSET/$1" "$APPICONSET/$1"
}

emit icon_16x16.png       16
emit icon_16x16@2x.png    32
emit icon_32x32.png       32
emit icon_32x32@2x.png    64
emit icon_128x128.png     128
emit icon_128x128@2x.png  256
emit icon_256x256.png     256
emit icon_256x256@2x.png  512
emit icon_512x512.png     512
emit icon_512x512@2x.png  1024

cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$(dirname "$ICONSET")"
echo "✅ $OUT ($(du -h "$OUT" | cut -f1)) + $APPICONSET"
