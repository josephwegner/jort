#!/usr/bin/env python3
"""Audit compiler module edges, with negative fixtures usable before extraction."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
CONTAINMENT_TARGETS = {'JortJavaScriptBroker', 'JortJavaScriptWorker'}
ALLOWED = {
    'JortToolContracts': {'Foundation'},
    'JortToolRuntime': {'Foundation', 'CryptoKit', 'Security', 'Darwin', 'JortToolContracts', 'JortJavaScriptClient'},
    'JortSettings': {'Foundation', 'CryptoKit', 'Security', 'Darwin', 'SQLite3', 'JortToolContracts'},
    'JortDocument': {'Foundation', 'CryptoKit', 'os', 'JortToolContracts'},
    'JortAppKit': {'Foundation', 'AppKit', 'QuartzCore', 'CoreText', 'UniformTypeIdentifiers', 'JortDocument', 'JortPersistence', 'JortSettings', 'JortToolContracts'},
}


def containment_errors(project_text):
    """Keep QuickJS and the old in-process shim out of shipping process graphs."""
    errors = []
    if '  JortJavaScript:\n' in project_text:
        errors.append('shipping project still declares JortJavaScript')
    worker = target_body(project_text, 'JortJavaScriptWorker')
    if worker.count('path: Vendor/QuickJS') != 1:
        errors.append('shipping QuickJS must be compiled by exactly the disposable worker')
    app = target_body(project_text, 'Jort')
    broker = target_body(project_text, 'JortJavaScriptBroker')
    if 'JortJavaScriptTestOracle' in app:
        errors.append('nonshipping JavaScript oracle must not enter the app graph')
    required = {
        'JortJavaScriptBroker': 'type: xpc-service',
        'JortJavaScriptWorker': 'type: tool',
        'PRODUCT_BUNDLE_IDENTIFIER: dev.jort.javascript.broker': None,
        'PRODUCT_BUNDLE_IDENTIFIER: dev.jort.javascript.worker': None,
        'CODE_SIGN_ENTITLEMENTS: Configuration/JortJavaScriptBroker.entitlements': None,
        'CODE_SIGN_ENTITLEMENTS: Configuration/JortJavaScriptWorker.entitlements': None,
    }
    for target, requirement in required.items():
        if requirement is None:
            if target not in project_text:
                errors.append(f'missing containment configuration: {target}')
        elif not target_body(project_text, target) or requirement not in target_body(project_text, target):
            errors.append(f'{target} lacks {requirement}')
    if '      - target: JortJavaScriptBroker\n        embed: true' not in app:
        errors.append('app does not embed the private JavaScript broker')
    if ('      - target: JortJavaScriptWorker\n        embed: true' not in broker
            or '          subpath: Contents/Helpers' not in broker):
        errors.append('broker does not embed the disposable JavaScript worker in Contents/Helpers')
    if '      - target: JortJavaScriptWorker\n' in app:
        errors.append('app must not separately embed the disposable JavaScript worker')
    return errors


def target_body(project_text, target):
    """Return one two-space-indented target's YAML body.

    XcodeGen target properties are nested at four or more spaces.  Do not split
    on any two-space line: that incorrectly treats the target's first property
    (for example ``type``) as the next target.
    """
    header = re.search(rf'^  {re.escape(target)}:\s*$', project_text, re.M)
    if header is None:
        return ''
    next_header = re.search(r'^  [^\s#][^:\n]*:\s*(?:#.*)?$',
                            project_text[header.end():], re.M)
    end = header.end() + next_header.start() if next_header else len(project_text)
    return project_text[header.end():end]


def entitlement_errors(broker, worker):
    prohibited = {
        'com.apple.security.network.client', 'com.apple.security.network.server',
        'com.apple.security.files.user-selected.read-only',
        'com.apple.security.files.user-selected.read-write',
        'com.apple.security.files.downloads.read-only',
        'com.apple.security.files.downloads.read-write',
        'com.apple.security.files.documents.read-only',
        'com.apple.security.files.documents.read-write',
        'com.apple.security.application-groups', 'keychain-access-groups',
        'com.apple.security.automation.apple-events',
        'com.apple.security.device.camera', 'com.apple.security.device.microphone',
        'com.apple.security.device.usb', 'com.apple.security.device.bluetooth',
        'com.apple.security.print', 'com.apple.security.cs.allow-jit',
        'com.apple.security.cs.allow-unsigned-executable-memory',
        'com.apple.security.cs.disable-library-validation',
    }
    errors = []
    if broker != {'com.apple.security.app-sandbox': True}:
        errors.append('broker entitlements must contain only App Sandbox')
    if worker != {
        'com.apple.security.app-sandbox': True,
        'com.apple.security.inherit': True,
    }:
        errors.append('worker entitlements must contain exactly App Sandbox and inherit')
    for name, values in [('broker', broker), ('worker', worker)]:
        for key in prohibited.intersection(values):
            errors.append(f'{name} contains prohibited entitlement: {key}')
        if any('temporary-exception' in key for key in values):
            errors.append(f'{name} contains a temporary exception entitlement')
    return errors

def violations(module, source):
    imports = re.findall(r'^\s*(?:@\w+\s+)?import\s+(\w+)', source, re.M)
    errors = [f'{module} imports {edge}' for edge in imports if edge not in ALLOWED[module]]
    if module == 'JortToolContracts':
        errors += [f'{module} references {symbol}' for symbol in ['URLSession', 'URLRequest', 'FileManager', 'SQLite3', 'jort_js_'] if re.search(r'\b' + symbol, source)]
    if module == 'JortAppKit':
        errors += [f'{module} references {symbol}' for symbol in ['ToolRuntime', 'OpenRouterProvider', 'BoundedOpenRouterTransport', 'URLSession', 'jort_js_'] if re.search(r'\b' + symbol, source)]
    if re.search(r'\bstatic\s+var\s+(?:shared|services|serviceLocator)\b', source) or re.search(r'\bstatic\s+var\s+\w+[^\n]*(?:ToolExecuting|ToolInvocationCoordinating|ModelProvider|SettingsStore)', source):
        errors.append(f'{module} declares mutable global service lookup')
    return errors

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        fixtures = json.loads((ROOT / 'Tests/Architecture/forbidden-tool-edges.json').read_text())
        for fixture in fixtures:
            assert violations(fixture['module'], fixture['source']), fixture
        for module in ALLOWED:
            assert not violations(module, 'import Foundation\n')
        valid = '''\
  JortJavaScriptBroker:
    type: xpc-service
    dependencies:
      - target: JortJavaScriptWorker
        embed: true
        copy:
          destination: wrapper
          subpath: Contents/Helpers
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.jort.javascript.broker
        CODE_SIGN_ENTITLEMENTS: Configuration/JortJavaScriptBroker.entitlements
  JortJavaScriptWorker:
    type: tool
    sources:
      - path: Vendor/QuickJS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.jort.javascript.worker
        CODE_SIGN_ENTITLEMENTS: Configuration/JortJavaScriptWorker.entitlements
  Jort:
    dependencies:
      - target: JortJavaScriptBroker
        embed: true
'''
        assert not containment_errors(valid)
        assert containment_errors(valid.replace('type: tool', 'type: framework'))
        assert containment_errors(valid.replace(
            '  JortJavaScriptBroker:\n    type: xpc-service\n    dependencies:\n'
            '      - target: JortJavaScriptWorker\n        embed: true\n        copy:\n'
            '          destination: wrapper\n          subpath: Contents/Helpers\n',
            '  JortJavaScriptBroker:\n    type: xpc-service\n'))
        # Regression: target extraction must keep all four-space nested
        # properties from the real XcodeGen file, not stop at ``type``.
        real_project = (ROOT / 'project.yml').read_text()
        worker_body = target_body(real_project, 'JortJavaScriptWorker')
        assert 'type: tool' in worker_body
        assert 'path: Vendor/QuickJS' in worker_body
        assert 'CODE_SIGN_ENTITLEMENTS: Configuration/JortJavaScriptWorker.entitlements' in worker_body
        assert not containment_errors(real_project)
        assert not entitlement_errors(
            {'com.apple.security.app-sandbox': True},
            {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True})
        assert entitlement_errors(
            {'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True},
            {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True})
        print(f'{len(fixtures)} forbidden dependency fixtures rejected.')
        return
    errors = []
    errors += containment_errors((ROOT / 'project.yml').read_text())
    broker = plistlib.loads((ROOT / 'Configuration/JortJavaScriptBroker.entitlements').read_bytes())
    worker = plistlib.loads((ROOT / 'Configuration/JortJavaScriptWorker.entitlements').read_bytes())
    errors += entitlement_errors(broker, worker)
    for module in ALLOWED:
        for path in (ROOT / 'Sources' / module).rglob('*.swift'):
            errors += [f'{path.relative_to(ROOT)}: {e}' for e in violations(module, path.read_text())]
    project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / 'Jort.xcodeproj/project.pbxproj')]))['objects']
    for value in project.values():
        module = value.get('name')
        if value.get('isa') != 'PBXNativeTarget' or module not in ALLOWED:
            continue
        for dep in value.get('dependencies', []):
            target = project.get(project[dep].get('target'), {}).get('name')
            if target and target not in ALLOWED[module]:
                errors.append(f'{module} target depends on {target}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print('Tool module dependencies comply.')

if __name__ == '__main__':
    main()
