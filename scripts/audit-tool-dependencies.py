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
        'PRODUCT_BUNDLE_IDENTIFIER: dev.jort.editor.javascript-broker': None,
        'PRODUCT_BUNDLE_IDENTIFIER: dev.jort.editor.javascript-worker': None,
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


def release_identity_errors(project_text, local_entitlements, development_entitlements, production_entitlements):
    """Check the source declarations that define the signed-release boundary."""
    errors = []
    app = target_body(project_text, 'Jort')
    expected = {
        'PRODUCT_BUNDLE_IDENTIFIER: dev.jort.editor',
        'CODE_SIGN_ENTITLEMENTS: $(JORT_APP_ENTITLEMENTS)',
        'CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO',
        'ENABLE_HARDENED_RUNTIME: YES',
        'JortCredentialEnvironment: $(JORT_CREDENTIAL_ENVIRONMENT)',
        'JortExpectedTeamIdentifier: $(JORT_PRODUCTION_TEAM_ID)',
    }
    for value in expected:
        if value not in app:
            errors.append(f'app lacks {value}')
    expected_development = {
        'keychain-access-groups': ['$(AppIdentifierPrefix)dev.jort.editor.development.credentials'],
    }
    expected_production = {
        'keychain-access-groups': ['$(AppIdentifierPrefix)dev.jort.editor.credentials'],
    }
    if local_entitlements != {
        'com.apple.security.get-task-allow': True,
        'com.apple.security.cs.disable-library-validation': True,
    }:
        errors.append('credential-free local app entitlements must contain only local debug exceptions')
    if development_entitlements != expected_development:
        errors.append('development app entitlements must contain only the development Keychain group')
    if production_entitlements != expected_production:
        errors.append('production app entitlements must contain only the production Keychain group')
    if 'com.apple.security.app-sandbox' in development_entitlements or 'com.apple.security.app-sandbox' in production_entitlements:
        errors.append('app must not be sandboxed for direct distribution')
    for value in (
        'CODE_SIGN_IDENTITY: \'-\'',
        'JORT_BUILD_AUDIENCE: local-only',
        'JORT_APP_ENTITLEMENTS: Configuration/JortLocal.entitlements',
        'JORT_CREDENTIAL_ENVIRONMENT: development',
    ):
        if value not in project_text:
            errors.append(f'missing explicit signing configuration: {value}')
    return errors


def credential_canary_errors(source):
    """The disposable Keychain probe must retain device-only accessibility.

    This is a static complement to the signed integration canary: both create
    and update paths must pass the same accessibility restriction to Security.
    """
    errors = []
    create = source.split('static int create_canary(', 1)
    if len(create) != 2 or 'CFDictionarySetValue(item, kSecAttrAccessible, kSecAttrAccessibleWhenUnlockedThisDeviceOnly);' not in create[1]:
        errors.append('credential canary create lacks device-only accessibility')
    update = source.split('CFMutableDictionaryRef attributes =', 1)
    if len(update) != 2 or 'CFDictionarySetValue(attributes, kSecAttrAccessible,' not in update[1] or 'kSecAttrAccessibleWhenUnlockedThisDeviceOnly' not in update[1]:
        errors.append('credential canary update lacks device-only accessibility')
    return errors


def peer_identity_build_errors(project_text):
    """Keep the ad-hoc peer exception out of every shipping Release target."""
    errors = []
    for target in ('JortJavaScriptClient', 'JortJavaScriptBroker'):
        body = target_body(project_text, target)
        if body.count('JORT_JS_ALLOW_ADHOC=1') != 1:
            errors.append(f'{target} must define the ad-hoc peer exception only for Debug')
        if not re.search(
                r'configs:\n\s+Debug:\n\s+GCC_PREPROCESSOR_DEFINITIONS: '
                r"\['\$\(inherited\)', 'JORT_JS_ALLOW_ADHOC=1'\]", body):
            errors.append(f'{target} Debug configuration lacks the explicit local peer exception')
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
        PRODUCT_BUNDLE_IDENTIFIER: dev.jort.editor.javascript-broker
        CODE_SIGN_ENTITLEMENTS: Configuration/JortJavaScriptBroker.entitlements
  JortJavaScriptWorker:
    type: tool
    sources:
      - path: Vendor/QuickJS
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.jort.editor.javascript-worker
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
        assert not peer_identity_build_errors(real_project)
        assert not release_identity_errors(
            real_project,
            {
                'com.apple.security.get-task-allow': True,
                'com.apple.security.cs.disable-library-validation': True,
            },
            {'keychain-access-groups': ['$(AppIdentifierPrefix)dev.jort.editor.development.credentials']},
            {'keychain-access-groups': ['$(AppIdentifierPrefix)dev.jort.editor.credentials']})
        assert not entitlement_errors(
            {'com.apple.security.app-sandbox': True},
            {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True})
        assert entitlement_errors(
            {'com.apple.security.app-sandbox': True, 'com.apple.security.network.client': True},
            {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True})
        canary = (ROOT / 'Tests/ReleaseIdentity/CredentialCanary.c').read_text()
        assert not credential_canary_errors(canary)
        assert credential_canary_errors(canary.replace(
            'CFDictionarySetValue(attributes, kSecAttrAccessible,\n                         kSecAttrAccessibleWhenUnlockedThisDeviceOnly);\n', ''))
        print(f'{len(fixtures)} forbidden dependency fixtures rejected.')
        return
    errors = []
    errors += containment_errors((ROOT / 'project.yml').read_text())
    errors += peer_identity_build_errors((ROOT / 'project.yml').read_text())
    broker = plistlib.loads((ROOT / 'Configuration/JortJavaScriptBroker.entitlements').read_bytes())
    worker = plistlib.loads((ROOT / 'Configuration/JortJavaScriptWorker.entitlements').read_bytes())
    local_entitlements = plistlib.loads((ROOT / 'Configuration/JortLocal.entitlements').read_bytes())
    development_entitlements = plistlib.loads((ROOT / 'Configuration/JortDevelopment.entitlements').read_bytes())
    production_entitlements = plistlib.loads((ROOT / 'Configuration/JortProduction.entitlements').read_bytes())
    errors += entitlement_errors(broker, worker)
    errors += release_identity_errors(
        (ROOT / 'project.yml').read_text(), local_entitlements,
        development_entitlements, production_entitlements)
    errors += credential_canary_errors((ROOT / 'Tests/ReleaseIdentity/CredentialCanary.c').read_text())
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
