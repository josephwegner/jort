#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
root = Path(__file__).resolve().parent.parent
expected = (root / '.xcodegen-version').read_text().strip()
actual = subprocess.check_output(['xcodegen', '--version'], text=True).strip().removeprefix('Version: ').strip()
if actual != expected:
    sys.exit(f'Use XcodeGen {expected}; found {actual}.')
paths = [root / 'Jort/Info.plist', root / 'Jort.xcodeproj/project.pbxproj'] + sorted((root / 'Jort.xcodeproj/xcshareddata').rglob('*'))
before = {p: p.read_bytes() for p in paths if p.is_file()}
subprocess.run(['xcodegen', 'generate'], cwd=root, check=True)
changed = [str(p.relative_to(root)) for p, data in before.items() if p.read_bytes() != data]
if changed:
    sys.exit('Generated configuration drift: ' + ', '.join(changed))
print('Generated project and plist match project.yml.')
