#!/bin/bash
# User-run/CI only: creates and ad-hoc signs an app and an accessibility test runner.
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project "$JORT_ROOT/Jort.xcodeproj" -scheme Jort -configuration Debug -derivedDataPath "$JORT_ROOT/.build-ui-tests" -destination 'platform=macOS' -only-testing:JortUITests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
