#!/bin/zsh
# Builds AudioMac.app (universal Intel + Apple Silicon, macOS 11+) into ./build
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild -project AudioMac.xcodeproj -target AudioMac -configuration Release \
  SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" build | grep -E "error:|warning:|BUILD" | grep -v appintents || true

test -d build/Release/AudioMac.app && echo "Built build/Release/AudioMac.app"
