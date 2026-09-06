#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
version="${VOICEOVER_VERSION:-0.1.0}"
build="${VOICEOVER_BUILD:-1}"
identity="${VOICEOVER_SIGNING_IDENTITY:-Developer ID Application: Harish Gupta (V7SF7XDP3N)}"
app="$project_root/dist/VoiceOver-$version-test.$build/VoiceOver.app"

if [[ -e "$app" ]]; then
    echo "Refusing to overwrite existing app: $app" >&2
    exit 1
fi

cd "$project_root"
swift build -c release --scratch-path .build-current
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Voice" artifacts/icon.iconset
cp .build-current/arm64-apple-macosx/release/VoiceOver "$app/Contents/MacOS/VoiceOver"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/Voice/* "$app/Contents/Resources/Voice/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string VoiceOver' "$app/Contents/Info.plist"

swift scripts/make-icon.swift artifacts/icon-1024.png
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" artifacts/icon-1024.png --out "artifacts/icon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" artifacts/icon-1024.png --out "artifacts/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns artifacts/icon.iconset -o "$app/Contents/Resources/VoiceOver.icns"

codesign --force --options runtime --timestamp --entitlements Resources/VoiceOver.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "$app"
