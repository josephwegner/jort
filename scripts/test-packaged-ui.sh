#!/bin/bash
# Build the runner in Debug, but launch the independently packaged Release app.
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
test -d "$JORT_ROOT/dist/Jort.app"
xcodebuild -project "$JORT_ROOT/Jort.xcodeproj" -scheme Jort -configuration Debug -derivedDataPath "$JORT_ROOT/.build-packaged-ui-tests" -destination 'platform=macOS' -only-testing:JortUITests/PackagedJortUITests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- test
