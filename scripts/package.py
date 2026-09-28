#!/usr/bin/env python3
"""Validate a fresh locally signed app, then atomically replace the artifact."""
import ctypes
import os
from pathlib import Path
import plistlib
import re
import shutil
import sys
import tempfile


FRAMEWORKS = [
    'JortDocument', 'JortPersistence', 'JortAppKit', 'JortSettings',
    'JortToolContracts', 'JortJavaScriptClient', 'JortToolRuntime',
]
BROKER = 'Contents/XPCServices/JortJavaScriptBroker.xpc/Contents/MacOS/JortJavaScriptBroker'
WORKER = 'Contents/XPCServices/JortJavaScriptBroker.xpc/Contents/Helpers/JortJavaScriptWorker'


def package(source, destination):
    source, destination = Path(source), Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.jort-stage-', dir=destination.parent))
    staged = staging / 'Jort.app'
    try:
        shutil.copytree(source, staged, symlinks=True)
        info = plistlib.loads((staged / 'Contents/Info.plist').read_bytes())
        spec = (Path(__file__).resolve().parent.parent / 'project.yml').read_text()
        for key, setting in [('CFBundleShortVersionString', 'MARKETING_VERSION'), ('CFBundleVersion', 'CURRENT_PROJECT_VERSION')]:
            expected = re.search(r'^\s*' + setting + r':\s*(.+)$', spec, re.M).group(1).strip('"\' ')
            if info.get(key) != expected:
                raise ValueError(f'{key}: expected {expected}, found {info.get(key)}')
        executable = staged / 'Contents/MacOS' / info['CFBundleExecutable']
        if not os.access(executable, os.X_OK):
            raise ValueError('Missing executable')
        if not (staged / 'Contents/Resources' / info['CFBundleIconFile']).is_file():
            raise ValueError('Missing icon')
        for module in FRAMEWORKS:
            if not (staged / f'Contents/Frameworks/{module}.framework/{module}').is_file():
                raise ValueError(f'Missing {module}')
        for nested in [BROKER, WORKER]:
            if not os.access(staged / nested, os.X_OK):
                raise ValueError(f'Missing nested executable: {nested}')
        if destination.exists():
            libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
            swap = libc.renameatx_np
            swap.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
            if swap(-2, os.fsencode(staged), -2, os.fsencode(destination), 2) != 0:
                raise OSError(ctypes.get_errno(), 'Atomic app swap failed')
        else:
            os.rename(staged, destination)
    finally:
        shutil.rmtree(staging)
    print(f'Built {destination} — locally signed, not a distribution artifact.')


if __name__ == '__main__':
    package(*sys.argv[1:])
