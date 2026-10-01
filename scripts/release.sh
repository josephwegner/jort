#!/usr/bin/env bash
set +x
set -euo pipefail
JORT_RELEASE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$JORT_RELEASE_ROOT/scripts/release.py" "$@"
