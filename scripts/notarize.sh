#!/bin/zsh
# Builds, signs with a Developer ID certificate, notarizes and staples SoundLanes.app for other Macs (SPEC §11 M4).
# One-time setup (needs a paid Apple Developer Program membership):
#   1. Install a "Developer ID Application" certificate in the login keychain.
#   2. xcrun notarytool store-credentials soundlanes-notary --apple-id <id> --team-id <team> --password <app-specific>
# Usage: scripts/notarize.sh            → build/SoundLanes.zip ready to distribute
set -euo pipefail
cd "${0:A:h}/.."

identity=${SOUNDLANES_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}
if [[ -z "$identity" ]]; then
  echo "오류: Developer ID Application 인증서가 없습니다. Apple Developer Program에서 발급받아 키체인에 설치하세요." >&2
  exit 1
fi
profile=${SOUNDLANES_NOTARY_PROFILE:-soundlanes-notary}

SOUNDLANES_SIGN_IDENTITY="$identity" scripts/bundle-app.sh release
app=build/SoundLanes.app
zip=build/SoundLanes.zip
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"   # re-zip with the stapled ticket
echo "배포 파일: $zip"
