#!/usr/bin/env python3
"""Prepare a run-owned GUI-test derivative of a credential-free local app."""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
PRODUCTION_ID = 'dev.jort.editor'
LOCAL_ENTITLEMENTS = {'com.apple.security.get-task-allow': True,
                      'com.apple.security.cs.disable-library-validation': True}
XCODE_TEST_EXCEPTIONS = {
    'com.apple.security.temporary-exception.files.absolute-path.read-only': ['/'],
    'com.apple.security.temporary-exception.mach-lookup.global-name': [
        'com.apple.testmanagerd', 'com.apple.dt.testmanagerd.runner', 'com.apple.coresymbolicationd'],
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, check=False)
    require(result.returncode == 0, 'command failed: ' + arguments[0])
    return result.stdout + result.stderr


def read_plist(path):
    with path.open('rb') as stream:
        return plistlib.load(stream)


def write_plist(path, value):
    with path.open('wb') as stream:
        plistlib.dump(value, stream)


def unlinked(path):
    path = Path(os.path.abspath(path))
    require(not any(part.is_symlink() for part in [path, *path.parents]),
            'symlink in input path')
    return path


def source_path(path):
    path = unlinked(path)
    relative = path.relative_to(ROOT)
    parts = relative.parts
    local = (len(parts) >= 5 and parts[0].startswith('.build-')
             and parts[1:3] == ('Build', 'Products') and parts[-1] == 'Jort.app')
    require(relative == Path('dist/Jort.app') or local, 'source outside allowed build/package paths')
    require(path.is_dir(), 'source application missing')
    return path


def signing_facts(app, allow_test_exceptions=False):
    command(['codesign', '--verify', '--deep', '--strict', str(app)])
    details = command(['codesign', '--display', '--verbose=4', str(app)]).decode()
    fields = dict(line.split('=', 1) for line in details.splitlines() if '=' in line)
    require(fields.get('Signature') == 'adhoc', 'application must be ad-hoc signed')
    require(fields.get('TeamIdentifier') in (None, 'not set'), 'Team ID forbidden')
    require(fields.get('Identifier') == PRODUCTION_ID, 'unexpected signing identifier')
    raw = command(['codesign', '--display', '--entitlements', ':-', str(app)])
    # codesign diagnostics may precede the XML on stderr.
    start = raw.find(b'<?xml')
    require(start >= 0, 'missing effective entitlements')
    end = raw.find(b'</plist>', start)
    require(end >= 0, 'invalid effective entitlements')
    entitlements = plistlib.loads(raw[start:end + len(b'</plist>')])
    keys = set(entitlements)
    expected = set(LOCAL_ENTITLEMENTS)
    # Build-for-testing injects these exact exceptions. Permit only this known
    # source shape; never propagate them into the isolated application's signature.
    if allow_test_exceptions and keys == expected | set(XCODE_TEST_EXCEPTIONS):
        require(all(entitlements[key] == value for key, value in XCODE_TEST_EXCEPTIONS.items()),
                'unexpected Xcode test exceptions')
        keys -= set(XCODE_TEST_EXCEPTIONS)
    require(keys == expected
            and all(entitlements[key] is True for key in LOCAL_ENTITLEMENTS),
            'unexpected effective entitlements')
    return dict(LOCAL_ENTITLEMENTS)


def payload(app):
    # Reuse the release verifier's signature-independent Mach-O fingerprint.
    from release_validation import macho_contract
    return macho_contract(app / 'Contents/MacOS/Jort')[0]


def inventory(app):
    result = {}
    for directory, folders, files in os.walk(app, followlinks=False):
        for name in folders + files:
            path = Path(directory) / name
            relative = path.relative_to(app).as_posix()
            mode = path.lstat().st_mode
            if path.is_symlink():
                require(path.resolve().is_relative_to(app.resolve()) and path.exists(),
                        'escaping or broken bundle symlink')
                value = ('link', os.readlink(path), mode)
            elif path.is_dir():
                value = ('directory', mode)
            else:
                require(path.is_file(), 'special bundle file')
                value = ('file', hashlib.sha256(path.read_bytes()).hexdigest(), mode)
            result[relative] = value
    return result


def derivative_inventory(snapshot):
    return {key: value for key, value in snapshot.items()
            if key not in ('Contents/Info.plist', 'Contents/MacOS/Jort', 'Contents/_CodeSignature')
            and not key.startswith('Contents/_CodeSignature/')}


def absolute_testroot(value, products):
    """Keep product references valid when the xctestrun moves; leave TESTHOST alone."""
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(products))
    if isinstance(value, list):
        return [absolute_testroot(item, products) for item in value]
    if isinstance(value, dict):
        return {absolute_testroot(key, products): absolute_testroot(item, products)
                for key, item in value.items()}
    return value


def targets(document):
    metadata = document.get('__xctestrun_metadata__', {})
    version = metadata.get('FormatVersion', 1)
    require(version in (1, 2), 'unsupported xctestrun version')
    if version == 2:
        configurations = document.get('TestConfigurations')
        require(isinstance(configurations, list) and configurations, 'missing test configurations')
        records = []
        for configuration in configurations:
            group = configuration.get('TestTargets')
            require(isinstance(group, list), 'missing test targets')
            records.extend((record.get('BlueprintName'), record) for record in group)
        return records
    return [(name, value) for name, value in document.items()
            if name != '__xctestrun_metadata__' and isinstance(value, dict)]


def test_target(document, products):
    matches = []
    allowed = {'UITargetAppPath', 'UITargetAppBundleIdentifier', 'UITargetAppEnvironmentVariables',
               'UITargetAppCommandLineArguments', 'UITargetAppPerformanceAntipatternCheckerEnabled'}
    for name, record in targets(document):
        keys = {key for key in record if key.startswith('UITarget')}
        require(keys <= allowed, 'unknown UI target launch fields')
        if name != 'JortUITests':
            require(not keys, 'unexpected UI application launch record')
            host = record.get('TestHostPath', '')
            require('.app' not in host, 'unexpected application host')
            continue
        original_path = record.get('UITargetAppPath')
        require(isinstance(original_path, str), 'missing UI application launch path')
        original_app = source_path(original_path.replace('__TESTROOT__', str(products)))
        require(original_app.is_relative_to(products), 'original UI target outside products')
        original_info = read_plist(unlinked(original_app / 'Contents/Info.plist'))
        require(original_info.get('CFBundleIdentifier') == PRODUCTION_ID,
                'unexpected original UI plist identifier')
        if 'UITargetAppBundleIdentifier' in record:
            require(record['UITargetAppBundleIdentifier'] == PRODUCTION_ID,
                    'unexpected original UI bundle identifier')
        if 'UITargetAppCommandLineArguments' in record:
            arguments = record['UITargetAppCommandLineArguments']
            require(isinstance(arguments, list) and all(isinstance(arg, str) for arg in arguments),
                    'invalid UI application command-line arguments')
        if 'UITargetAppPerformanceAntipatternCheckerEnabled' in record:
            require(type(record['UITargetAppPerformanceAntipatternCheckerEnabled']) is bool,
                    'invalid UI application performance checker flag')
        host = record.get('TestHostPath')
        require(isinstance(host, str), 'missing UI runner host')
        host_path = unlinked(host.replace('__TESTROOT__', str(products)))
        relative_host = host_path.relative_to(products)
        require(relative_host.parts[-1:] == ('JortUITests-Runner.app',)
                or relative_host.parts[-4:] == ('JortUITests-Runner.app', 'Contents',
                                                'MacOS', 'JortUITests-Runner'),
                'unexpected UI runner host')
        matches.append(record)
    require(len(matches) == 1, 'expected exactly one JortUITests target')
    return matches[0]


def prepare(products, source=None, kind='debug'):
    require(kind in ('debug', 'packaged'), 'invalid test kind')
    products = unlinked(products)
    require(products.is_dir(), 'products directory missing')
    products.relative_to(ROOT)
    runs = sorted(products.glob('*.xctestrun'))
    require(len(runs) == 1, 'expected exactly one xctestrun file')
    original_run = unlinked(runs[0])
    document = read_plist(original_run)
    target = test_target(document, products)
    source = source_path(source or products / 'Debug/Jort.app')
    require(not (source / 'Contents/Info.plist').is_symlink()
            and not (source / 'Contents/MacOS/Jort').is_symlink(), 'linked outer application files')
    info = read_plist(source / 'Contents/Info.plist')
    require(info.get('CFBundleIdentifier') == PRODUCTION_ID
            and info.get('CFBundleExecutable') == 'Jort', 'unexpected source identity')
    require(info.get('JortCredentialEnvironment') == 'development'
            and not info.get('JortExpectedTeamIdentifier'), 'credential environment is not local')
    require(not list(source.rglob('*.provisionprofile')), 'embedded profile forbidden')
    entitlements = signing_facts(source, allow_test_exceptions=kind == 'debug'
                                 and source.is_relative_to(products))
    before, original_payload = inventory(source), payload(source)
    parent = unlinked(products / '.isolated-ui')
    parent.mkdir(exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix=kind + '-', dir=parent))
    app = run / 'Jort.app'
    shutil.copytree(source, app, symlinks=True)
    identifier = PRODUCTION_ID + '.uitests.' + kind + '.' + uuid.uuid4().hex
    info.update(CFBundleIdentifier=identifier,
                CFBundleDisplayName='Jort UI Tests' if kind == 'debug' else 'Jort Packaged UI Tests',
                JortUITestIsolation=True)
    write_plist(app / 'Contents/Info.plist', info)
    entitlement_path = run / 'local-entitlements.plist'
    write_plist(entitlement_path, entitlements)
    command(['codesign', '--force', '--sign', '-', '--identifier', PRODUCTION_ID,
             '--options', 'runtime', '--entitlements', str(entitlement_path), str(app)])
    signing_facts(app)
    require(payload(app) == original_payload, 'executable payload changed')
    require(derivative_inventory(inventory(app)) == derivative_inventory(before),
            'unexpected derivative content changes')
    require(inventory(source) == before, 'original application changed')
    require(read_plist(app / 'Contents/Info.plist') == info, 'isolated plist changed')
    # Unlike the original Xcode-built app, this copied identity has never been
    # registered. XCTest launches by bundle ID, so register only this exact copy.
    command(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
             '-f', '-R', '-trusted', str(app)])
    store = Path(tempfile.mkdtemp(prefix='jort-ui-default-store-',
                                  dir='/private/tmp')).resolve()
    target['UITargetAppPath'] = str(app)
    target['UITargetAppBundleIdentifier'] = identifier
    environment = target.setdefault('EnvironmentVariables', {})
    environment.update(JORT_UI_TEST_APP_PATH=str(app), JORT_UI_TEST_APP_ID=identifier,
                       JORT_UI_TEST_KIND=kind)
    app_environment = target.setdefault('UITargetAppEnvironmentVariables', {})
    app_environment.update(JORT_DATA_DIRECTORY=str(store),
                           JORT_UI_TEST_ISOLATION_NONCE=str(uuid.uuid4()))
    require(all(record.get('UITargetAppBundleIdentifier') != PRODUCTION_ID
                for _, record in targets(document)), 'production UI launch identity remains')
    output = run / original_run.name
    write_plist(output, absolute_testroot(document, products))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products-dir', required=True, type=Path)
    parser.add_argument('--source-app', type=Path)
    parser.add_argument('--kind', required=True, choices=('debug', 'packaged'))
    args = parser.parse_args()
    try:
        output = prepare(args.products_dir, args.source_app, args.kind)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        print('UI isolation refused: ' + str(error)[:240], file=sys.stderr)
        return 1
    print('Prepared isolated ' + args.kind + ' GUI test bundle.', file=sys.stderr)
    print(output)
    return 0


if __name__ == '__main__':
    sys.exit(main())
