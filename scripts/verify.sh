#!/bin/zsh
# Builds AudioMac, relaunches it and saves a screenshot of its window to build/verify/.
# Usage: scripts/verify.sh [--no-build]
# Prints the screenshot path on the last line. Leaves the app running: quit it with
#   osascript -e 'tell application "AudioMac" to quit'
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" != "--no-build" ]]; then
  ./build.sh
fi

APP="$PWD/build/Release/AudioMac.app"
test -d "$APP" || { echo "Missing $APP: build first" >&2; exit 1; }

# Relaunch from scratch so the new build is the one on screen.
if pgrep -x AudioMac >/dev/null; then
  osascript -e 'tell application "AudioMac" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x AudioMac >/dev/null || break; sleep 0.25; done
  pkill -x AudioMac 2>/dev/null || true
fi
open "$APP"

# Wait for the window (CGWindowList needs no special permission for IDs and bounds).
WINDOW_ID=""
for _ in {1..40}; do
  WINDOW_ID=$(swift - <<'SWIFT' 2>/dev/null || true
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "AudioMac"
    && (w[kCGWindowLayer as String] as? Int) == 0 {
    print(w[kCGWindowNumber as String] as? Int ?? 0)
    break
}
SWIFT
)
  [[ -n "$WINDOW_ID" ]] && break
  sleep 0.5
done
[[ -n "$WINDOW_ID" ]] || { echo "AudioMac window did not appear" >&2; exit 1; }

sleep 1.5  # let the UI settle (source lists, level meters)
mkdir -p build/verify
OUT="build/verify/AudioMac-$(date +%Y%m%d-%H%M%S).png"
if ! screencapture -o -l "$WINDOW_ID" "$OUT" 2>/dev/null || [[ ! -s "$OUT" ]]; then
  echo "Screenshot failed: grant Screen Recording to the terminal/app running this script (System Settings → Privacy & Security)" >&2
  exit 1
fi
echo "$PWD/$OUT"
