#!/bin/bash
# Builds Mac Duo.app (universal), runs the tests, and packages a drag-to-install DMG.
#   ./scripts/build.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
BUILD=$(date +%Y%m%d%H%M)
OUT=build
APP="$OUT/Mac Duo.app"
SIGN_ID="${SIGN_ID:--}"   # set SIGN_ID to a Developer ID to sign for real; "-" = ad-hoc

rm -rf "$OUT" && mkdir -p "$OUT"

echo "▸ Tests"
swiftc -O Sources/Core/*.swift Tests/main.swift -o "$OUT/tests"
"$OUT/tests"

echo "▸ Compile (arm64 + x86_64)"
for arch in arm64 x86_64; do
  swiftc -O -whole-module-optimization -target $arch-apple-macos14.0 \
    Sources/Core/*.swift Sources/App/*.swift -o "$OUT/MacDuo-$arch"
done
lipo -create "$OUT/MacDuo-arm64" "$OUT/MacDuo-x86_64" -output "$OUT/MacDuo"

echo "▸ Bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT/MacDuo" "$APP/Contents/MacOS/MacDuo"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
swiftc -O scripts/make_icon.swift -o "$OUT/make_icon"
"$OUT/make_icon" "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$OUT/AppIcon.iconset/icon_512x512@2x.png" "$OUT/icon.png"

echo "▸ Sign ($SIGN_ID)"
codesign --force --deep --options runtime --timestamp=none --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Mac Duo" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT/MacDuo.dmg" >/dev/null
(cd "$OUT" && ditto -c -k --keepParent "Mac Duo.app" MacDuo.zip)
shasum -a 256 "$OUT/MacDuo.dmg" "$OUT/MacDuo.zip" | tee "$OUT/SHA256SUMS.txt"
echo "✓ $OUT/MacDuo.dmg"
