#!/bin/bash
# Build the runner in Debug; launch an isolated copy of the packaged Release app.
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
test -d "$JORT_ROOT/dist/Jort.app"
exec bash "$JORT_ROOT/scripts/run-isolated-ui-tests.sh" \
  --derived-data "$JORT_ROOT/.build-packaged-ui-tests" --kind packaged \
  --source-app "$JORT_ROOT/dist/Jort.app"
