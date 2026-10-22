#!/bin/zsh
# Builds SoundLanes.app into build/ and signs it.
# Usage: scripts/bundle-app.sh [debug|release]
# A stable signing identity keeps the TCC audio-capture grant across rebuilds;
# override with SOUNDLANES_SIGN_IDENTITY. Falls back to ad-hoc signing.
set -euo pipefail
cd "${0:A:h}/.."

config=${1:-release}
swift build -c "$config" --product SoundLanesApp
bin=$(swift build -c "$config" --show-bin-path)

app=build/SoundLanes.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/SoundLanesApp" "$app/Contents/MacOS/SoundLanes"
cp Resources/App-Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

identity=${SOUNDLANES_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')}
if [[ -z "$identity" ]]; then
  echo "경고: 서명 인증서가 없어 ad-hoc 서명합니다. 다시 빌드할 때마다 오디오 권한을 새로 받아야 할 수 있습니다." >&2
  identity=-
fi
codesign --force --options runtime --timestamp=none \
  --entitlements Resources/SoundLanes.entitlements --sign "$identity" "$app"
echo "$app"
