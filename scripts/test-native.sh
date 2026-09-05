#!/bin/bash
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project "$JORT_ROOT/Jort.xcodeproj" -scheme JortNativeTests -configuration Debug -derivedDataPath "$JORT_ROOT/.build-native-tests" -destination 'platform=macOS' JORT_PERFORMANCE_ENFORCE="${JORT_PERFORMANCE_ENFORCE:-0}" test
