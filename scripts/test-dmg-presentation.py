#!/usr/bin/env python3
"""Desktop-only smoke test of real disk-image creation, without launching Jort."""
from pathlib import Path
import plistlib
import subprocess
import struct
import tempfile
from unittest.mock import patch

import release


class PresentationRunner(release.Runner):
    def __call__(self, command, **kwargs):
        if command[0] != 'osascript':
            return super().__call__(command, **kwargs)
        # This credential-free test may print Finder diagnostics; the release
        # runner deliberately suppresses external tool output.
        result = subprocess.run(command, cwd=self.root, env=self.environment,
                                capture_output=True, timeout=60)
        if result.returncode:
            raise ValueError(result.stderr.decode(errors='replace')[:1500])
        return result.stdout


def saved_finder_blob(data, key):
    marker = struct.pack('>I', 1) + '.'.encode('utf-16be') + key + b'blob'
    record = data.find(marker)
    release.require(record >= 0, 'missing saved Finder background settings')
    start = record + len(marker)
    release.require(start + 4 <= len(data), 'truncated Finder record')
    length = struct.unpack('>I', data[start:start + 4])[0]
    release.require(start + 4 + length <= len(data), 'truncated Finder settings')
    return data[start + 4:start + 4 + length]


def verify_saved_background(layout, volume_uuid):
    # The Finder background-picture getter fails with -10000 on some macOS
    # versions. Check the actual saved icon-view plist instead. A DS_Store blob
    # record is UTF-16 filename + four-byte key/type + length-prefixed bytes.
    data = layout.read_bytes()
    options = plistlib.loads(saved_finder_blob(data, b'icvp'))
    alias = options.get('backgroundImageAlias')
    release.require(options.get('backgroundType') == 2 and isinstance(alias, bytes)
                    and b'.background/background.png' in alias,
                    'branded background was not saved in the compressed image')
    # Finder also saves the background's URL bookmark (pBBk). Its volume UUID
    # distinguishes this image from an already-mounted installer with the same
    # title and relative background filename. No alias resolution/mounting needed.
    bookmark = saved_finder_blob(data, b'pBBk')
    release.require(isinstance(volume_uuid, str) and len(volume_uuid) == 36
                    and volume_uuid.upper().encode('ascii') in bookmark.upper()
                    and b'.background' in bookmark and b'background.png' in bookmark,
                    'saved background belongs to another volume')


def main():
    # Use a harmless placeholder, not the user's installed or running app.
    (release.ROOT / 'dist').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.release-presentation-', dir=release.ROOT / 'dist') as temporary:
        stage = Path(temporary).resolve()
        app = stage / 'Jort.app'; app.mkdir()
        (app / 'README.txt').write_text('Installer presentation smoke-test placeholder. Not an application.')
        image = stage / 'presentation-test.dmg'
        runner = PresentationRunner()
        with patch.object(release, 'validate_bundle'):
            release.build_image(app, {}, image, runner, stage)
        mount = stage / 'verify-mount'; mount.mkdir()
        attached = False
        try:
            data = runner(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), '-plist', str(image)])
            attached = True
            attachment = plistlib.loads(data)
            release.require(any(entity.get('mount-point') == str(mount) for entity in attachment['system-entities']), 'unexpected smoke-test mount')
            release.validate_image_presentation(mount)
            volume = plistlib.loads(runner(['diskutil', 'info', '-plist', str(mount)]))
            verify_saved_background(mount / '.DS_Store', volume.get('VolumeUUID'))
            # Read the layout from the final compressed image, not Finder's
            # in-memory view of the writable intermediate.
            result = runner(['osascript', str(release.ROOT / 'scripts/layout-dmg.applescript'), str(mount), mount.as_uri() + '/', 'verify'], timeout=60)
            release.require(result.strip() == b'true', 'Finder layout did not survive compression')
        finally:
            if attached:
                runner(['hdiutil', 'detach', str(mount)])
    print('PASS: branded background, window geometry, and drag-to-Applications icon positions in compressed image')


if __name__ == '__main__':
    main()
