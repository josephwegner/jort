#!/bin/bash
# Normal checks build frameworks and command-line test bundles, never Jort.app.
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$JORT_ROOT/scripts/test-foundation.sh"
"$JORT_ROOT/scripts/test-native.sh"
python3 "$JORT_ROOT/scripts/test-packaging.py"
