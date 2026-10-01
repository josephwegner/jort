#!/usr/bin/env python3
"""Final inside-out Apple Development signing for the protected fixture lane."""
from __future__ import annotations

import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile

from release_manifest import load, require
from release_signing import signing_plan


def commands(app, manifest, identity, scratch):
    """Build the reviewed inner-to-outer signing command sequence."""
    require(not manifest['production'], 'development manifest required')
    profile = manifest.get('provisioningProfile')
    require(profile is not None and profile['environment'] == 'development',
            'development provisioning profile required')
    require(identity.upper() == profile['signingCertificateSHA1'],
            'development signing identity does not match provisioning profile')
    result = []
    for item in signing_plan(manifest):
        command = ['codesign', '--force', '--sign', identity, '--identifier', item['identifier'],
                   '--options', 'runtime']
        if item['entitlements']:
            entitlements = Path(scratch) / (item['target'] + '.entitlements')
            entitlements.write_bytes(plistlib.dumps(item['entitlements']))
            command.extend(['--generate-entitlement-der', '--entitlements', str(entitlements)])
        command.append(str(Path(app) / item['path']))
        result.append(command)
    return result


def sign(app, manifest, identity, runner=None, scratch=None):
    def invoke(args):
        if runner is not None:
            return runner(args)
        result = subprocess.run(args, capture_output=True)
        require(result.returncode == 0, 'codesign failed')
        return result.stdout + result.stderr
    with tempfile.TemporaryDirectory(prefix='.jort-development-sign-') if scratch is None else _existing(scratch) as directory:
        for command in commands(app, manifest, identity, directory):
            invoke(command)
        invoke(['codesign', '--verify', '--deep', '--strict', '--verbose=4', str(app)])


class _existing:
    def __init__(self, path): self.path = str(path)
    def __enter__(self): return self.path
    def __exit__(self, *_): return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--identity', required=True)
    args = parser.parse_args()
    sign(args.app, load(args.manifest), args.identity)


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        raise SystemExit('Apple Development signing rejected: ' + str(error))
