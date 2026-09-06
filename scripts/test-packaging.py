#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import plistlib
import tempfile
spec = importlib.util.spec_from_file_location('package', Path(__file__).with_name('package.py'))
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp); source = root / 'Build/Jort.app'; destination = root / 'dist/Jort.app'
    for sub in ['MacOS', 'Resources', 'Frameworks']:
        (source / 'Contents' / sub).mkdir(parents=True)
    (source / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.3.0', 'CFBundleVersion': '3', 'CFBundleExecutable': 'Jort', 'CFBundleIconFile': 'AppIcon.icns'}))
    binary = source / 'Contents/MacOS/Jort'; binary.write_text('fixture'); binary.chmod(0o755)
    (source / 'Contents/Resources/AppIcon.icns').write_text('fixture')
    for name in ['JortDocument', 'JortPersistence', 'JortAppKit']:
        folder = source / f'Contents/Frameworks/{name}.framework'; folder.mkdir(); (folder / name).write_text('fixture')
    module.package(source, destination)
    (destination / 'stale-file').write_text('must disappear')
    module.package(source, destination)
    assert not (destination / 'stale-file').exists()
    (source / 'Contents/Resources/AppIcon.icns').unlink()
    try:
        module.package(source, destination)
        raise AssertionError('Expected validation failure')
    except ValueError:
        assert (destination / 'Contents/Resources/AppIcon.icns').exists()
print('Fresh packaging and failed-validation preservation pass.')
