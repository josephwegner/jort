#!/bin/bash
set -euo pipefail
JORT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JORT_ICON_SOURCE="$JORT_ROOT/Jort/Resources/IconSources/jort-color.png"
JORT_ICON_OUTPUT="$JORT_ROOT/Jort/Resources/AppIcon.icns"
JORT_ICON_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/jort-icon.XXXXXX")"
trap 'rm -rf "$JORT_ICON_TEMP"' EXIT
mkdir "$JORT_ICON_TEMP/AppIcon.iconset"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$JORT_ICON_SOURCE" --out "$JORT_ICON_TEMP/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  /usr/bin/sips -z "$((size * 2))" "$((size * 2))" "$JORT_ICON_SOURCE" --out "$JORT_ICON_TEMP/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 - "$JORT_ICON_TEMP" <<'PY'
from pathlib import Path
import struct
import sys
root = Path(sys.argv[1])
# Modern ICNS stores PNG representations in typed, length-prefixed chunks.
representations = [('icp4', 16, ''), ('icp5', 32, ''), ('ic07', 128, ''),
                   ('ic08', 256, ''), ('ic09', 512, ''), ('ic11', 16, '@2x'),
                   ('ic12', 32, '@2x'), ('ic13', 128, '@2x'),
                   ('ic14', 256, '@2x'), ('ic10', 512, '@2x')]
chunks = []
for kind, size, suffix in representations:
    data = (root / 'AppIcon.iconset' / f'icon_{size}x{size}{suffix}.png').read_bytes()
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(data) + 8) + data)
payload = b''.join(chunks)
(root / 'AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
PY
mv "$JORT_ICON_TEMP/AppIcon.icns" "$JORT_ICON_OUTPUT"
