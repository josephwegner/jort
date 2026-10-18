#!/bin/bash
# User-run/CI only: launches a unique, credential-free test copy, never live Jort.
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec bash "$JORT_ROOT/scripts/run-isolated-ui-tests.sh" \
  --derived-data "$JORT_ROOT/.build-ui-tests" --kind debug
