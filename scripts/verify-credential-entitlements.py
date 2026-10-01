#!/usr/bin/env python3
"""Verify the built main-app credential group and helper/framework denial."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess


def entitlements(path):
    result = subprocess.run(
        ['codesign', '-d', '--entitlements', ':-', str(path)], capture_output=True)
    if result.returncode:
        raise ValueError('signature entitlement inspection failed')
    return plistlib.loads(result.stdout) if result.stdout.strip() else {}


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('--team-id', default=(os.environ.get('JORT_PRODUCTION_TEAM_ID')
                                          or os.environ.get('JORT_DEVELOPMENT_TEAM_ID')))
args = parser.parse_args()
if not args.team_id or not re.fullmatch(r'[A-Z0-9]{10}', args.team_id):
    raise SystemExit('a development or production Team ID must be an exact ten-character value')
app = args.app.resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
environment = info.get('JortCredentialEnvironment')
groups = {
    'development': args.team_id + '.dev.jort.editor.development.credentials',
    'production': args.team_id + '.dev.jort.editor.credentials',
}
if environment not in groups:
    raise SystemExit('main app has no recognized credential environment')
expected = groups[environment]
if entitlements(app) != {'keychain-access-groups': [expected]}:
    raise SystemExit('main app does not have its exact credential group')
denied = [
    app / 'Contents/XPCServices/JortJavaScriptBroker.xpc',
    app / 'Contents/XPCServices/JortJavaScriptBroker.xpc/Contents/Helpers/JortJavaScriptWorker',
    *sorted((app / 'Contents/Frameworks').glob('*.framework')),
]
for path in denied:
    if 'keychain-access-groups' in entitlements(path):
        raise SystemExit('nested code unexpectedly carries a credential group: ' + path.name)
print('Credential entitlement isolation passed for ' + environment + '.')
