#!/bin/zsh
# Rebuild Clem, reinstall into /Applications, and relaunch it.
# Usage:  ./Scripts/refresh.sh
set -e
cd "$(dirname "$0")/.."

echo "→ building…"
./Scripts/make-app.sh          # swift build + assemble + sign + install to /Applications

echo "→ relaunching…"
pkill -f "Clem.app/Contents/MacOS/Clem" 2>/dev/null || true
sleep 1
open -a /Applications/Clem.app

# Nudge Finder/Dock so the icon isn't stale in the UI.
touch /Applications/Clem.app
echo "✓ Clem refreshed in /Applications and relaunched"
