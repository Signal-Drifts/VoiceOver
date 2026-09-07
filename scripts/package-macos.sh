#!/usr/bin/env bash
set -euo pipefail

# Builds VoiceOver, embeds Seed-VC, signs every Mach-O file, creates a DMG,
# submits it with notarytool, and staples Apple's notarization ticket.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
version="${VOICEOVER_VERSION:-0.1.0}"
build="${VOICEOVER_BUILD:-1}"
identity="${VOICEOVER_SIGNING_IDENTITY:-Developer ID Application: Harish Gupta (V7SF7XDP3N)}"
notary_profile="${VOICEOVER_NOTARY_PROFILE:-kiln}"
architecture="$(uname -m)"
seed_root="$project_root/third_party/seed-vc"
release_root="$project_root/dist/VoiceOver-$version-release"
app="$release_root/VoiceOver.app"
dmg="$project_root/dist/VoiceOver_${version}_${architecture}.dmg"

[[ -x "$seed_root/.venv/bin/python" ]] || { echo "Run scripts/setup-seed-vc.sh first." >&2; exit 1; }
[[ -n "$identity" && "$identity" != "-" ]] || { echo "A Developer ID Application identity is required." >&2; exit 1; }
[[ -n "$notary_profile" ]] || { echo "VOICEOVER_NOTARY_PROFILE is required." >&2; exit 1; }
[[ ! -e "$app" && ! -e "$dmg" ]] || { echo "Release output already exists; move it before rebuilding." >&2; exit 1; }

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

runtime="$app/Contents/Resources/SeedVC"
mkdir -p "$runtime"
rsync -a --exclude '.git' --exclude '.venv' --exclude '__pycache__' --exclude 'reconstructed' "$seed_root/" "$runtime/"
python_base="$($seed_root/.venv/bin/python -c 'import sys; print(sys.base_prefix)')"
ditto "$python_base" "$runtime/python"
ditto "$seed_root/.venv" "$runtime/venv"
for executable in python python3 python3.10; do
    [[ -e "$runtime/venv/bin/$executable" || -L "$runtime/venv/bin/$executable" ]] && unlink "$runtime/venv/bin/$executable"
    ln -s ../../python/bin/python3.10 "$runtime/venv/bin/$executable"
done
cat > "$runtime/venv/pyvenv.cfg" <<'PYVENV'
home = ../python/bin
implementation = CPython
version_info = 3.10
include-system-site-packages = false
PYVENV

# Python must never mutate the sealed application bundle at runtime.
find "$runtime" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$runtime" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

# Seed-VC inference does not use the upstream demo, notebook, training, or web UI packages.
site_packages="$runtime/venv/lib/python3.10/site-packages"
find "$site_packages" -mindepth 1 -maxdepth 1 \( \
    -name 'gradio*' -o -name 'pandas*' -o -name 'sklearn*' -o -name 'scikit_learn*' -o \
    -name 'grpc*' -o -name 'jedi*' -o -name 'ipython*' -o -name 'IPython*' -o \
    -name 'modelscope*' -o -name 'resemblyzer*' -o \
    -name 'Crypto*' -o -name 'pycryptodome*' -o \
    -name 'cryptography*' -o -name 'torchvision*' -o -name 'FreeSimpleGUI*' -o \
    -name 'fastapi*' -o -name 'starlette*' -o -name 'uvicorn*' -o -name 'jupyter*' -o \
    -name 'notebook*' -o -name 'jieba*' \
\) -exec rm -rf {} +

while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q 'Mach-O'; then
        codesign --force --options runtime --timestamp --sign "$identity" "$candidate"
    fi
done < <(find "$runtime" -type f -print0)
codesign --force --options runtime --timestamp --entitlements Resources/VoiceOverPython.entitlements --sign "$identity" "$runtime/python/bin/python3.10"
codesign --force --options runtime --timestamp --entitlements Resources/VoiceOver.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

stage="$(mktemp -d "${TMPDIR:-/tmp}/voiceover-dmg.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/VoiceOver.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname VoiceOver -srcfolder "$stage" -ov -format UDZO "$dmg"
hdiutil verify "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

echo "$app"
echo "$dmg"
