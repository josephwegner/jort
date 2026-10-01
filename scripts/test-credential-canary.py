#!/usr/bin/env python3
"""Run signed Keychain allow/deny canaries without disclosing their value."""
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import tempfile
import uuid

from provisioning_profile import (
    inspect as inspect_profile,
    resolve_apple_development_identity,
)


ROOT = Path(__file__).resolve().parent.parent
identity_selector = os.environ.get('JORT_APPLE_DEVELOPMENT_IDENTITY', '')
team = os.environ.get('JORT_DEVELOPMENT_TEAM_ID', '')
profile_values = [value for value in (
    os.environ.get('JORT_DEVELOPMENT_PROVISIONING_PROFILE'),
    os.environ.get('JORT_DEVELOPMENT_PROVISIONING_PROFILE_PATH'),
) if value]
if not identity_selector or len(team) != 10:
    raise SystemExit('protected Apple Development identity and Team ID are required')
if len(set(profile_values)) != 1:
    raise SystemExit('one JORT_DEVELOPMENT_PROVISIONING_PROFILE path is required')
profile = Path(profile_values[0]).expanduser()
app = ROOT / 'dist/Jort.app'
try:
    # Resolve display names only once, then hand codesign and profile validation
    # the exact certificate fingerprint. A duplicate display name cannot select
    # an arbitrary key from the login keychain.
    identity = resolve_apple_development_identity(identity_selector, team)
except ValueError as error:
    raise SystemExit('Apple Development identity rejected: ' + str(error)) from error

group = team + '.dev.jort.editor.development.credentials'
service = 'dev.jort.editor.canary.' + uuid.uuid4().hex
account = 'canary-' + uuid.uuid4().hex
canary = secrets.token_bytes(32)
updated_canary = bytes([canary[0] ^ 0xFF]) + canary[1:]
captured = []


def run(args, label, input_bytes=None):
    result = subprocess.run(args, cwd=ROOT, input=input_bytes, capture_output=True)
    captured.extend((result.stdout, result.stderr))
    if result.returncode:
        # Tool output is deliberately not included: it may contain Keychain
        # diagnostics or the disposable canary.
        raise RuntimeError(label + ' failed')


def signed_role(path):
    """Read one role's sealed identity and entitlement payload without logging it."""
    run(['codesign', '--verify', '--strict', str(path)], 'signed role verification')
    result = subprocess.run(['codesign', '-d', '--verbose=4', '--entitlements', ':-', str(path)],
                            cwd=ROOT, capture_output=True)
    captured.extend((result.stdout, result.stderr))
    if result.returncode:
        raise RuntimeError('signed role inspection failed')
    if b'invalid entitlements blob' in result.stderr.lower():
        raise RuntimeError('signed role has invalid effective entitlements')
    match = next((line.removeprefix('Identifier=') for line in result.stderr.decode(
        errors='replace').splitlines() if line.startswith('Identifier=')), None)
    if match is None:
        raise RuntimeError('signed role has no identifier')
    try:
        values = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    except plistlib.InvalidFileException as error:
        raise RuntimeError('signed role entitlements are not a plist') from error
    return {'identifier': match, 'entitlements': values}


def require_built_roles():
    """Couple every disposable fixture to the just-built shipping topology."""
    paths = {
        'app': app,
        'broker': app / 'Contents/XPCServices/JortJavaScriptBroker.xpc',
        'worker': (app / 'Contents/XPCServices/JortJavaScriptBroker.xpc'
                   / 'Contents/Helpers/JortJavaScriptWorker'),
    }
    if any(not path.is_file() and not path.is_dir() for path in paths.values()):
        raise RuntimeError('dist/Jort.app signed role topology is incomplete')
    roles = {name: signed_role(path) for name, path in paths.items()}
    expected = {
        'app': {'identifier': 'dev.jort.editor',
                'entitlements': {'keychain-access-groups': [group]}},
        'broker': {'identifier': 'dev.jort.editor.javascript-broker',
                   'entitlements': {'com.apple.security.app-sandbox': True}},
        'worker': {'identifier': 'dev.jort.editor.javascript-worker',
                   'entitlements': {'com.apple.security.app-sandbox': True,
                                    'com.apple.security.inherit': True}},
    }
    if roles != expected:
        raise RuntimeError('dist/Jort.app role identity or entitlement policy differs')
    return roles


def require_host_profile(path):
    facts = inspect_profile(path, team, 'development', identity)
    if facts['applicationIdentifier'] != team + '.dev.jort.editor':
        raise ValueError('development profile does not authorize dev.jort.editor')
    if facts['keychainAccessGroup'] != group:
        raise ValueError('development profile does not authorize the development credential group')
    if facts['signingCertificateSHA1'] != identity:
        raise ValueError('development profile signing certificate binding differs')


def make_bundle(root, name, role, executable, provisioning_profile=None):
    bundle = root / (name + '.app')
    macos = bundle / 'Contents/MacOS'
    macos.mkdir(parents=True)
    binary = macos / name
    shutil.copy2(executable, binary)
    info = {
        'CFBundleExecutable': name,
        'CFBundleIdentifier': role['identifier'],
        'CFBundleName': name,
        'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '1',
        'CFBundleVersion': '1',
    }
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    if provisioning_profile is not None:
        shutil.copy2(provisioning_profile, bundle / 'Contents/embedded.provisionprofile')
    command = ['codesign', '--force', '--sign', identity, '--identifier', role['identifier'],
               '--options', 'runtime', '--timestamp=none']
    if role['entitlements']:
        # Signing inputs are scratch files, not nested bundle components.
        entitlement_path = root / (name + '.app.entitlements')
        entitlement_path.write_bytes(plistlib.dumps(role['entitlements']))
        command.extend(['--generate-entitlement-der', '--entitlements', str(entitlement_path)])
    command.append(str(bundle))
    run(command, role['identifier'] + ' signing')
    return bundle, binary


def make_broker_fixture(root, executable, broker_role, worker_role):
    """Build the same broker/worker nested topology used by the app."""
    broker = root / 'JortJavaScriptBroker.xpc'
    worker = broker / 'Contents/Helpers/JortJavaScriptWorker'
    worker.parent.mkdir(parents=True)
    shutil.copy2(executable, worker)
    (broker / 'Contents/MacOS').mkdir(parents=True)
    broker_binary = broker / 'Contents/MacOS/JortJavaScriptBroker'
    shutil.copy2(executable, broker_binary)
    (broker / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'JortJavaScriptBroker',
        'CFBundleIdentifier': broker_role['identifier'],
        'CFBundlePackageType': 'XPC!',
        'CFBundleShortVersionString': '1', 'CFBundleVersion': '1',
    }))
    worker_entitlements = root / 'worker.entitlements'
    worker_entitlements.write_bytes(plistlib.dumps(worker_role['entitlements']))
    broker_entitlements = root / 'broker.entitlements'
    broker_entitlements.write_bytes(plistlib.dumps(broker_role['entitlements']))
    run(['codesign', '--force', '--sign', identity, '--identifier',
         worker_role['identifier'], '--options', 'runtime', '--timestamp=none',
         '--generate-entitlement-der', '--entitlements', str(worker_entitlements), str(worker)], 'worker signing')
    run(['codesign', '--force', '--sign', identity, '--identifier',
         broker_role['identifier'], '--options', 'runtime', '--timestamp=none',
         '--generate-entitlement-der', '--entitlements', str(broker_entitlements), str(broker)], 'broker signing')
    return broker_binary, worker


def assert_no_secret_output():
    output = b''.join(captured)
    # Include every selector in the scan: future tool changes cannot quietly
    # turn a Keychain query or its canary into CI output.
    # The stable access group is intentionally present in the signed-role
    # inspection; dynamic selectors and both disposable values may never be.
    forbidden = (canary, updated_canary, service.encode(), account.encode())
    if any(value in output for value in forbidden):
        raise RuntimeError('credential canary diagnostics disclosed protected data')


require_host_profile(profile)
roles = require_built_roles()
with tempfile.TemporaryDirectory(prefix='jort-credential-canary-') as temporary:
    stage = Path(temporary)
    source = ROOT / 'Tests/ReleaseIdentity/CredentialCanary.c'
    executable = stage / 'CredentialCanary'
    run(['xcrun', 'clang', '-framework', 'CoreFoundation', '-framework', 'Security',
         str(source), '-o', str(executable)], 'canary compilation')
    host, _ = make_bundle(stage, 'Jort', roles['app'], executable, profile)
    _, helper_binary = make_bundle(stage, 'JortCredentialCanaryHelper', {
        'identifier': 'dev.jort.editor.credential-canary-helper', 'entitlements': {},
    }, executable)
    broker_binary, worker_binary = make_broker_fixture(
        stage, executable, roles['broker'], roles['worker'])
    failure = None
    create_attempted = False
    try:
        create_attempted = True
        host_binary = host / 'Contents/MacOS/Jort'
        run([str(host_binary), 'create', group, service, account],
            'authorized main-app canary create/read/update', canary)
        # Each denied probe returns the same success result for entitlement,
        # authentication, and not-found outcomes, so it cannot serve as an
        # error oracle for the credential value or item existence.
        for label, probe in (('differently identified helper', helper_binary),
                             ('JavaScript broker', broker_binary)):
            run([str(probe), 'probe', group, service, account], label + ' canary probe')
        run([str(broker_binary), 'broker-probe', str(worker_binary), group, service, account],
            'sandboxed broker to inherited JavaScript worker canary probe')
    except Exception as error:
        failure = error
    finally:
        if create_attempted:
            try:
                run([str(host / 'Contents/MacOS/Jort'), 'cleanup', group, service, account],
                    'authorized main-app canary cleanup')
            except Exception as error:
                if failure is None:
                    failure = error
        try:
            assert_no_secret_output()
        except Exception as error:
            if failure is None:
                failure = error
    if failure is not None:
        raise failure
print('Signed credential canary isolation passed.')
