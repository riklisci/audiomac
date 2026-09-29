#!/bin/zsh
# Compila AudioMac.app (universale Intel + Apple Silicon, macOS 11+) in ./build
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild -project AudioMac.xcodeproj -target AudioMac -configuration Release \
  SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" build | grep -E "error|warning:|BUILD" || true

test -d build/Release/AudioMac.app && echo "Creato build/Release/AudioMac.app"
