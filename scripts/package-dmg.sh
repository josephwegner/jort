#!/usr/bin/env bash
set +x
set -euo pipefail
JORT_IMAGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$JORT_IMAGE_ROOT/scripts/package_dmg.py" "$@"
