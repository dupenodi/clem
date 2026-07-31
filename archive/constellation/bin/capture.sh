#!/bin/zsh
# Clem capture — bind this to a global hotkey.
# Usage: capture.sh [screen|window|selection]
MODE="${1:-screen}"
curl -s -m 90 -X POST http://localhost:7777/api/capture \
  -H 'Content-Type: application/json' \
  -d "{\"mode\":\"$MODE\"}" >/dev/null
