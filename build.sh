#!/bin/zsh
# Builds AudioMac.app (universal Intel + Apple Silicon, macOS 11+) into ./build
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild -project AudioMac.xcodeproj -target AudioMac -configuration Release \
  SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" build | grep -E "error:|warning:|BUILD" | grep -v appintents || true

APP=build/Release/AudioMac.app
test -d "$APP" || exit 1
# Rebuilds don't update the bundle's date, so Finder would keep showing a cached icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
