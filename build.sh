#!/bin/zsh
# Builds AudioMac.app (universal Intel + Apple Silicon, macOS 11+) into ./build
set -euo pipefail
cd "$(dirname "$0")"

# Sign with an Apple Development certificate when one is available: macOS privacy permissions
# (Screen Recording, Microphone) then survive rebuilds. Without one the app is signed ad-hoc and
# macOS asks for the permissions again after every build.
SIGNING=()
IDENTITY=$(security find-identity -v -p codesigning | awk '/"Apple Development/ { print $2; exit }')
if [[ -n "$IDENTITY" ]]; then
  SIGNING=(CODE_SIGN_IDENTITY="$IDENTITY")
  echo "Signing with Apple Development certificate $IDENTITY"
else
  echo "No Apple Development certificate found: signing ad-hoc"
fi

xcodebuild -project AudioMac.xcodeproj -target AudioMac -configuration Release \
  SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" "${SIGNING[@]}" build | grep -E "error:|warning:|BUILD" | grep -v appintents || true

APP=build/Release/AudioMac.app
test -d "$APP" || exit 1
# Rebuilds don't update the bundle's date, so Finder would keep showing a cached icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
