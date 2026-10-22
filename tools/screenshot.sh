#!/bin/bash
# Saves a screenshot of the Apple TV's screen. Usage (Git Bash): tools/screenshot.sh [out.png]
OUT=${1:-atvshot.png}
curl -sfo "$OUT" "http://${ATV_HOST:-192.168.0.101}/api/screenshot" && echo "$OUT"
