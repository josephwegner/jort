#!/bin/bash
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project "$JORT_ROOT/Jort.xcodeproj" -scheme Jort -configuration Release -derivedDataPath "$JORT_ROOT/.build" build
python3 "$JORT_ROOT/scripts/package.py" "$JORT_ROOT/.build/Build/Products/Release/Jort.app" "$JORT_ROOT/dist/Jort.app"
