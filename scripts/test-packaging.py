#!/usr/bin/env python3
"""Credential-free adversarial tests for the release contract and publication."""
import ast
import copy
from contextlib import nullcontext
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

import release
import release_manifest as manifests
import release_signing as signing
import release_validation as validation
import release_inputs
import provisioning_profile as profiles
import sign_development

spec = importlib.util.spec_from_file_location('package', Path(__file__).with_name('package.py'))
package = importlib.util.module_from_spec(spec); spec.loader.exec_module(package)
ROOT = Path(__file__).resolve().parent.parent
TEAM = 'ABCDE12345'
IDENTITY = 'A' * 40
PROFILE_CERTIFICATE = b'fixture profile certificate'
PROFILE_IDENTITY = hashlib.sha1(PROFILE_CERTIFICATE).hexdigest().upper()


def fixture(root):
    project = manifests.read_project()
    policy = json.loads((ROOT / 'Configuration/release-policy.json').read_text())
    graph = manifests.shipping_graph(project, policy)
    app = root / 'Jort.app'; app.mkdir()
    settings = []
    base = project['settings']['base']
    for name, node in graph.items():
        target = project['targets'][name]
        kind = policy['roles'][name]['role']
        values = dict(base, **target.get('settings', {}).get('base', {}))
        suffix = {'app': '.app', 'framework': '.framework', 'broker': '.xpc', 'worker': ''}[kind]
        product = name + suffix
        executable = name if kind == 'worker' else product + ('/Versions/A/' if kind == 'framework' else '/Contents/MacOS/') + name
        values.update(CONFIGURATION='Release', EXECUTABLE_NAME=name, FULL_PRODUCT_NAME=product,
                      EXECUTABLE_PATH=executable, ARCHS='arm64', FRAMEWORK_VERSION='A',
                      LD_RUNPATH_SEARCH_PATHS='', ENABLE_HARDENED_RUNTIME='YES')
        if kind == 'app':
            values['CODE_SIGN_ENTITLEMENTS'] = 'Configuration/JortProduction.entitlements'
        settings.append({'target': name, 'buildSettings': values})
        if kind != 'worker':
            location = app / node['path'] / ('Versions/A/Resources/Info.plist' if kind == 'framework' else 'Contents/Info.plist')
            location.parent.mkdir(parents=True, exist_ok=True)
            info = {'CFBundleIdentifier': values['PRODUCT_BUNDLE_IDENTIFIER'], 'CFBundleExecutable': name,
                    'CFBundleShortVersionString': str(base['MARKETING_VERSION']), 'CFBundleVersion': str(base['CURRENT_PROJECT_VERSION'])}
            if kind == 'app':
                info.update(
                    CFBundleIconFile='AppIcon.icns', JortCredentialEnvironment='production',
                    JortExpectedTeamIdentifier=TEAM)
            location.write_bytes(plistlib.dumps(info))
    manifest = manifests.generate(ROOT, settings, app, True, TEAM,
                                  {'sourceRevision': 'a' * 40, 'toolchain': 'Xcode fixture', 'xcodegen': 'fixture'})
    inspections = {}
    for name, item in manifest['files'].items():
        path = app / name; path.parent.mkdir(parents=True, exist_ok=True)
        if item['kind'] == 'code':
            path.write_bytes(b'\xcf\xfa\xed\xfe' + b'fixture code')
        elif 'source' in item:
            path.write_bytes((ROOT / item['source']).read_bytes() if 'plist' not in item else plistlib.dumps(item['plist']))
        elif item['kind'] == 'resource':
            path.write_bytes(b'APPL????')
        path.chmod(item['mode'])
    for name, target in manifest['symlinks'].items():
        path = app / name; path.parent.mkdir(parents=True, exist_ok=True); path.symlink_to(target)
    for name in manifest['directories']:
        (app / name).mkdir(parents=True, exist_ok=True)
    for item in manifest['objects']:
        inspections[item['target']] = {'architectures': ['arm64'],
                                      'slices': {'arm64': {'dependencies': ['/usr/lib/libSystem.B.dylib'], 'rpaths': item['runpaths'], 'engine': item['quickjs']}},
                                      'payload': ['payload-' + item['target']],
                                      'plists': [item['infoValues']] if item['role'] == 'worker' else []}
    def inspector(path):
        target = next(item['target'] for item in manifest['objects'] if path.as_posix().endswith('/' + item['executable']))
        return inspections[target]
    return app, manifest, inspections, inspector, settings


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.app, self.manifest, self.inspections, self.inspector, self.settings = fixture(self.root)

    def tearDown(self):
        self.temp.cleanup()

    def validate(self):
        return validation.validate_bundle(self.app, self.manifest, self.inspector)

    def test_complete_and_deterministic(self):
        self.validate()
        again = manifests.generate(ROOT, list(reversed(self.settings)), self.app, True, TEAM,
                                   {'sourceRevision': 'a' * 40, 'toolchain': 'Xcode fixture', 'xcodegen': 'fixture'})
        self.assertEqual(manifests.canonical(self.manifest), manifests.canonical(again))

    def test_provisioning_profile_rejects_wrong_authorization_and_freezes_facts(self):
        production_group = TEAM + '.dev.jort.editor.credentials'
        development_group = TEAM + '.dev.jort.editor.development.credentials'

        def payload(**changes):
            value = {
                'TeamIdentifier': [TEAM], 'ApplicationIdentifierPrefix': [TEAM],
                'Platform': ['OSX'], 'ProvisionsAllDevices': True,
                'DeveloperCertificates': [PROFILE_CERTIFICATE],
                'Entitlements': {'com.apple.application-identifier': TEAM + '.dev.jort.editor',
                                 'get-task-allow': False,
                                 'keychain-access-groups': [production_group]},
                'ExpirationDate': datetime.now(timezone.utc) + timedelta(days=1),
                'UUID': 'fixture-profile', 'Name': 'fixture profile',
            }
            value.update(changes)
            return plistlib.dumps(value)
        profile = self.root / 'profile.mobileprovision'; profile.write_bytes(b'fixture CMS bytes')
        decoder = lambda _: payload()
        facts = profiles.inspect(profile, TEAM, 'production', PROFILE_IDENTITY, decoder=decoder)
        self.assertEqual(facts['keychainAccessGroup'], production_group)
        self.assertEqual(facts['applicationIdentifier'], TEAM + '.dev.jort.editor')
        # TN3125 permits Team-scoped profile allowlist entries.  The app
        # entitlement remains the exact selected environment group.
        for groups in ([production_group], [TEAM + '.*'], [TEAM + '.dev.jort.editor.*'],
                       [TEAM + '.*', TEAM + '.unrelated.group'],
                       [production_group, 'com.apple.token'],
                       [production_group, development_group]):
            with self.subTest(authorized_groups=groups):
                self.assertEqual(
                    profiles.inspect(profile, TEAM, 'production', PROFILE_IDENTITY,
                                     decoder=lambda _, g=groups: payload(Entitlements={
                                         'com.apple.application-identifier': TEAM + '.dev.jort.editor',
                                         'get-task-allow': False,
                                         'keychain-access-groups': g}))['keychainAccessGroup'],
                    production_group)
        for change in (
            {'TeamIdentifier': ['OTHER12345']},
            {'ApplicationIdentifierPrefix': ['OTHER12345']},
            {'Platform': ['iOS']},
            {'ProvisionsAllDevices': False},
            {'ProvisionedDevices': ['fixture-device']},
            {'DeveloperCertificates': []},
            {'DeveloperCertificates': [PROFILE_CERTIFICATE, PROFILE_CERTIFICATE]},
            {'Entitlements': {'com.apple.application-identifier': TEAM + '.dev.other', 'get-task-allow': False, 'keychain-access-groups': [production_group]}},
            {'Entitlements': {'com.apple.application-identifier': TEAM + '.dev.jort.editor', 'application-identifier': TEAM + '.dev.jort.editor', 'get-task-allow': False, 'keychain-access-groups': [production_group]}},
            # Another Team, broad/malformed wildcards, and an unauthorized
            # group are all rejected. Unrelated exact entries are permitted.
            {'Entitlements': {'com.apple.application-identifier': TEAM + '.dev.jort.editor', 'get-task-allow': False, 'keychain-access-groups': ['OTHER12345.*']}},
            {'Entitlements': {'com.apple.application-identifier': TEAM + '.dev.jort.editor', 'get-task-allow': False, 'keychain-access-groups': ['*']}},
            {'Entitlements': {'com.apple.application-identifier': TEAM + '.dev.jort.editor', 'get-task-allow': False, 'keychain-access-groups': [TEAM + '*']}},
            {'Entitlements': {'com.apple.application-identifier': TEAM + '.dev.jort.editor', 'get-task-allow': False, 'keychain-access-groups': [TEAM + '.dev.*.credentials']}},
            {'Entitlements': {'com.apple.application-identifier': TEAM + '.dev.jort.editor', 'get-task-allow': False, 'keychain-access-groups': [TEAM + '.dev.jort.editor.other']}},
            {'ExpirationDate': datetime.now(timezone.utc) - timedelta(seconds=1)},
        ):
            with self.subTest(change=change):
                with self.assertRaises(ValueError):
                    profiles.inspect(profile, TEAM, 'production', PROFILE_IDENTITY, decoder=lambda _, c=change: payload(**c))
        altered = copy.deepcopy(self.manifest)
        altered['provisioningProfile'] = facts
        altered['files']['Contents/embedded.provisionprofile'] = {
            'kind': 'resource', 'mode': 420, 'sha256': facts['sha256']}
        manifests.validate_manifest(altered)
        for field, value in (
            ('sha256', '0' * 64),
            ('teamID', 'OTHER12345'),
            ('platform', 'iOS'),
            ('applicationIdentifier', TEAM + '.dev.other'),
            ('keychainAccessGroup', development_group),
        ):
            with self.subTest(field=field):
                drift = copy.deepcopy(altered); drift['provisioningProfile'][field] = value
                with self.assertRaises(ValueError):
                    manifests.validate_manifest(drift)
        with self.assertRaises(ValueError):
            profiles.inspect(profile, TEAM, 'production', 'B' * 40, decoder=decoder)
        (self.app / 'Contents/embedded.provisionprofile').write_bytes(b'wrong profile')
        with self.assertRaises(ValueError):
            validation.validate_bundle(self.app, altered, self.inspector)

    def test_embedding_profile_copies_bytes_without_source_extended_attributes(self):
        profile = self.root / 'profile.mobileprovision'
        profile.write_bytes(b'fixture CMS bytes')
        attribute = 'user.jort-provenance'
        xattr = subprocess.run(
            ['xattr', '-w', attribute, 'quarantined fixture', str(profile)], capture_output=True)
        if xattr.returncode != 0:
            self.skipTest('filesystem does not permit extended attributes')

        embedded = profiles.embed(profile, self.app)

        self.assertEqual(embedded.read_bytes(), profile.read_bytes())
        self.assertEqual(embedded.stat().st_mode & 0o777, 0o644)
        self.assertNotEqual(
            subprocess.run(['xattr', '-p', attribute, str(embedded)], capture_output=True).returncode, 0)

    def test_development_profile_semantics_and_final_signing_order(self):
        profile = self.root / 'development.mobileprovision'; profile.write_bytes(b'development profile')
        development = {
            'TeamIdentifier': [TEAM], 'ApplicationIdentifierPrefix': [TEAM], 'Platform': ['OSX'],
            'DeveloperCertificates': [PROFILE_CERTIFICATE], 'ProvisionedDevices': ['fixture-device'],
            'Entitlements': {'com.apple.application-identifier': TEAM + '.dev.jort.editor',
                             'keychain-access-groups': [TEAM + '.dev.jort.editor.development.credentials']},
            'ExpirationDate': datetime.now(timezone.utc) + timedelta(days=1),
            'UUID': 'development-fixture', 'Name': 'development fixture',
        }
        facts = profiles.inspect(profile, TEAM, 'development', PROFILE_IDENTITY,
                                 decoder=lambda _: plistlib.dumps(development), device_provider=lambda: 'fixture-device')
        with self.assertRaises(ValueError):
            profiles.inspect(profile, TEAM, 'production', PROFILE_IDENTITY, decoder=lambda _: plistlib.dumps(development))
        production = copy.deepcopy(development)
        production['Entitlements']['keychain-access-groups'] = [TEAM + '.dev.jort.editor.credentials']
        production['ProvisionsAllDevices'] = True
        del production['ProvisionedDevices']
        with self.assertRaises(ValueError):
            profiles.inspect(profile, TEAM, 'development', PROFILE_IDENTITY,
                             decoder=lambda _: plistlib.dumps(production), device_provider=lambda: 'fixture-device')
        manifest = copy.deepcopy(self.manifest)
        manifest['production'] = False
        manifest['provisioningProfile'] = facts
        manifest['files']['Contents/embedded.provisionprofile'] = {'kind': 'resource', 'mode': 420, 'sha256': facts['sha256']}
        for item in manifest['objects']:
            item['teamID'] = TEAM
            if item['role'] == 'app':
                item['entitlements'] = {'keychain-access-groups': [facts['keychainAccessGroup']]}
                item['entitlementInput'] = 'Configuration/JortDevelopment.entitlements'
                item['entitlementSHA256'] = manifests.digest(ROOT / item['entitlementInput'])
        manifests.validate_manifest(manifest)
        calls = []
        scratch = self.root / 'sign-scratch'; scratch.mkdir()
        sign_development.sign(self.app, manifest, PROFILE_IDENTITY, runner=calls.append, scratch=scratch)
        signing_calls = calls[:-1]
        self.assertEqual(calls[-1], ['codesign', '--verify', '--deep', '--strict', '--verbose=4', str(self.app)])
        self.assertEqual([command[-1] for command in signing_calls],
                         [str(self.app / item['path']) for item in signing.signing_plan(manifest)])
        for command, item in zip(signing_calls, signing.signing_plan(manifest)):
            self.assertIn('--options', command)
            self.assertEqual('--entitlements' in command, bool(item['entitlements']))
            self.assertEqual('--generate-entitlement-der' in command, bool(item['entitlements']))
            if item['entitlements']:
                self.assertEqual(plistlib.loads(Path(command[command.index('--entitlements') + 1]).read_bytes()),
                                 item['entitlements'])

    def test_distribution_signing_generates_der_only_for_entitled_roles(self):
        calls = []
        scratch = self.root / 'release-sign-scratch'; scratch.mkdir()
        with patch.object(signing, 'verify_object', return_value={}):
            signing.sign_all(self.app, self.manifest, TEAM, IDENTITY, calls.append, scratch)
        for command, item in zip(calls[:-1], signing.signing_plan(self.manifest)):
            self.assertEqual(command[-1], str(self.app / item['path']))
            self.assertEqual('--entitlements' in command, bool(item['entitlements']))
            self.assertEqual('--generate-entitlement-der' in command, bool(item['entitlements']))
            if item['entitlements']:
                self.assertEqual(plistlib.loads(Path(command[command.index('--entitlements') + 1]).read_bytes()),
                                 item['entitlements'])

    def canary_functions(self):
        # Load only definitions: the protected script's top-level work requires
        # real signing credentials and performs actual Keychain operations.
        path = ROOT / 'scripts/test-credential-canary.py'
        parsed = ast.parse(path.read_text(), filename=str(path))
        definitions = ast.Module(body=[node for node in parsed.body if isinstance(node, ast.FunctionDef)],
                                 type_ignores=[])
        namespace = {'ROOT': ROOT, 'Path': Path, 'plistlib': plistlib, 'shutil': shutil,
                     'subprocess': subprocess, 'identity': IDENTITY, 'captured': []}
        exec(compile(definitions, str(path), 'exec'), namespace)
        return namespace

    def test_canary_signatures_generate_der_only_for_entitled_roles(self):
        functions = self.canary_functions()
        calls = []
        functions['run'] = lambda command, label: calls.append(command)
        executable = self.root / 'canary'; executable.write_bytes(b'fixture executable')
        roles = {item['role']: item for item in self.manifest['objects']}
        functions['make_bundle'](self.root, 'Host', roles['app'], executable)
        functions['make_bundle'](self.root, 'Helper', {'identifier': 'fixture.helper', 'entitlements': {}}, executable)
        functions['make_broker_fixture'](self.root, executable, roles['broker'], roles['worker'])
        self.assertEqual(len(calls), 4)
        for command, entitlements in zip(calls, (roles['app']['entitlements'], {},
                                                  roles['worker']['entitlements'], roles['broker']['entitlements'])):
            self.assertEqual('--entitlements' in command, bool(entitlements))
            self.assertEqual('--generate-entitlement-der' in command, bool(entitlements))
            if entitlements:
                self.assertEqual(plistlib.loads(Path(command[command.index('--entitlements') + 1]).read_bytes()),
                                 entitlements)

    def test_canary_role_inspection_reads_verbose_identity_and_effective_entitlements(self):
        functions = self.canary_functions()
        functions['run'] = lambda command, label: None
        entitlements = {'keychain-access-groups': [TEAM + '.dev.jort.editor.development.credentials']}
        output = plistlib.dumps(entitlements)
        details = b'Executable=/fixture/Jort.app\nIdentifier=dev.jort.editor\nTeamIdentifier=ABCDE12345\n'
        with patch.object(subprocess, 'run', return_value=SimpleNamespace(
                returncode=0, stdout=output, stderr=details)) as inspect:
            self.assertEqual(functions['signed_role'](self.app),
                             {'identifier': 'dev.jort.editor', 'entitlements': entitlements})
            self.assertIn('--verbose=4', inspect.call_args.args[0])
        self.assertEqual(functions['captured'], [output, details])
        for stdout, stderr, code, message in (
            (output, b'no identifier', 0, 'no identifier'),
            (b'not a plist', details, 0, 'not a plist'),
            (output, details + b'warning: invalid entitlements blob. The OS will ignore these entitlements.',
             0, 'invalid effective entitlements'),
            (b'secret diagnostics', b'secret diagnostics', 1, 'inspection failed'),
        ):
            with self.subTest(message=message), patch.object(subprocess, 'run', return_value=SimpleNamespace(
                    returncode=code, stdout=stdout, stderr=stderr)):
                with self.assertRaisesRegex(RuntimeError, message) as failure:
                    functions['signed_role'](self.app)
                self.assertNotIn('secret diagnostics', str(failure.exception))

    def test_canary_bundle_entitlement_inputs_are_unique_and_outside_sealed_payload(self):
        functions = self.canary_functions()
        calls = []
        functions['run'] = lambda command, label: calls.append(command)
        executable = self.root / 'canary'; executable.write_bytes(b'fixture executable')
        profile = self.root / 'canary.provisionprofile'; profile.write_bytes(b'fixture profile')
        role = next(item for item in self.manifest['objects'] if item['role'] == 'app')
        paths = []
        for name in ('Host', 'SecondHost'):
            bundle, binary = functions['make_bundle'](self.root, name, role, executable, profile)
            command = calls[-1]
            entitlement_path = Path(command[command.index('--entitlements') + 1])
            paths.append(entitlement_path)
            self.assertEqual(entitlement_path.parent, self.root)
            self.assertFalse(entitlement_path.is_relative_to(bundle))
            self.assertEqual(plistlib.loads(entitlement_path.read_bytes()), role['entitlements'])
            self.assertEqual(list(bundle.rglob('*.entitlements')), [])
            self.assertEqual(binary.read_bytes(), executable.read_bytes())
            self.assertEqual((bundle / 'Contents/embedded.provisionprofile').read_bytes(), profile.read_bytes())
        self.assertNotEqual(*paths)

    def test_canary_selectors_are_unique_and_secret_scan_ignores_static_names(self):
        path = ROOT / 'scripts/test-credential-canary.py'
        parsed = ast.parse(path.read_text(), filename=str(path))
        selectors = ast.Module(body=[node for node in parsed.body if isinstance(node, ast.Assign)
                                    and any(isinstance(target, ast.Name) and target.id in ('service', 'account')
                                            for target in node.targets)], type_ignores=[])
        selector_code = compile(selectors, str(path), 'exec')
        first, second = {'uuid': uuid}, {'uuid': uuid}
        exec(selector_code, first)
        exec(selector_code, second)
        self.assertRegex(first['account'], r'^canary-[0-9a-f]{32}$')
        self.assertRegex(first['service'], r'^dev\.jort\.editor\.canary\.[0-9a-f]{32}$')
        self.assertEqual(len({first['account'], second['account'], first['service'], second['service']}), 4)

        functions = self.canary_functions()
        functions.update(account=first['account'], service=first['service'],
                         canary=bytes(range(32)), updated_canary=bytes(range(1, 33)))
        diagnostic = (b'/tmp/jort-credential-canary-fixture/Host.app.entitlements\n'
                      b'canary.entitlements\nIdentifier=dev.jort.editor.credential-canary-helper\n')
        functions['captured'] = [diagnostic]
        functions['assert_no_secret_output']()
        for protected in (first['account'].encode(), first['service'].encode(),
                          functions['canary'], functions['updated_canary']):
            with self.subTest(protected_kind='selector' if protected.startswith(b'canary-') else 'other'):
                functions['captured'] = [diagnostic, b'output=' + protected + b'\n']
                with self.assertRaisesRegex(RuntimeError, 'disclosed protected data'):
                    functions['assert_no_secret_output']()

    def test_canary_denial_probe_rejects_success_results_and_allocation_failure(self):
        # Exercise the production C probe with stubbed Security/CF calls. No
        # signing identity or Keychain is needed for the denial truth table.
        canary_source = (ROOT / 'Tests/ReleaseIdentity/CredentialCanary.c').read_text()
        probe = canary_source.split('static int probe_canary(', 1)[1].split('static int cleanup_canary(', 1)[0]
        harness = self.root / 'canary-probe-test.c'
        harness.write_text('''
#include <stdbool.h>
#include <stddef.h>
typedef void *CFMutableDictionaryRef;
typedef void *CFTypeRef;
typedef int OSStatus;
enum { errSecSuccess = 0 };
static bool allocated;
static OSStatus next_status;
static CFTypeRef next_result;
static int query_token, result_token, matching_calls, query_releases, result_releases;
static CFMutableDictionaryRef query(const char *group, const char *service,
                                    const char *account, bool returning_data) {
    (void)group; (void)service; (void)account;
    return allocated && returning_data ? &query_token : NULL;
}
static OSStatus SecItemCopyMatching(CFMutableDictionaryRef value, CFTypeRef *result) {
    if (value != &query_token) return 999;
    ++matching_calls;
    *result = next_result;
    return next_status;
}
static void CFRelease(CFTypeRef value) {
    if (value == &query_token) ++query_releases;
    if (value == &result_token) ++result_releases;
}
static int probe_canary(''' + probe + '''
int main(void) {
    const OSStatus statuses[] = {0, -25300, -34018, -25293, -25291, -50, 1};
    for (int allocation = 0; allocation <= 1; ++allocation) {
        for (int has_result = 0; has_result <= 1; ++has_result) {
            for (size_t i = 0; i < sizeof(statuses) / sizeof(statuses[0]); ++i) {
                allocated = allocation;
                next_status = statuses[i];
                next_result = has_result ? &result_token : NULL;
                matching_calls = query_releases = result_releases = 0;
                int actual = probe_canary("group", "service", "account");
                int expected = allocation && statuses[i] != 0 && !has_result ? 0 : 20;
                if (actual != expected) return 1;
                if (matching_calls != allocation || query_releases != allocation) return 2;
                if (result_releases != allocation * has_result) return 3;
            }
        }
    }
    return 0;
}
''')
        executable = self.root / 'canary-probe-test'
        compiled = subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(harness),
                                   '-o', str(executable)], capture_output=True, text=True)
        self.assertEqual(compiled.returncode, 0, compiled.stderr)
        result = subprocess.run([str(executable)], capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout + result.stderr, b'')

    def test_development_identity_resolution_is_exact_and_unambiguous(self):
        first = '1' * 40
        second = '2' * 40
        third = '3' * 40
        display_name = 'Apple Development: Fixture (DUX4WBNMB9)'
        listing = (f'  1) {first} "{display_name}"\n'
                   f'  2) {second} "Apple Development: Other (OTHER12345)"\n')
        certificate_teams = {first: TEAM, second: 'OTHER12345', third: TEAM}
        team = lambda fingerprint, _: certificate_teams[fingerprint]
        self.assertEqual(profiles.resolve_apple_development_identity(
            display_name, TEAM, runner=lambda _: listing, certificate_team=team), first)
        self.assertEqual(profiles.resolve_apple_development_identity(
            first.lower(), TEAM, runner=lambda _: listing, certificate_team=team), first)
        for selector, output in (
            ('missing', listing),
            (display_name, listing + f'  3) {third} "{display_name}"\n'),
        ):
            with self.subTest(selector=selector):
                with self.assertRaises(ValueError):
                    profiles.resolve_apple_development_identity(
                        selector, TEAM, runner=lambda _, value=output: value, certificate_team=team)

        with self.assertRaises(ValueError):
            profiles.resolve_apple_development_identity(
                first, 'WRONG12345', runner=lambda _: listing, certificate_team=team)

    def test_development_staging_disables_xcode_signing_only_after_identity_selection(self):
        build = (ROOT / 'scripts/build.sh').read_text()
        self.assertIn('derived_data="$stage/DerivedData"', build)
        self.assertIn('app="$derived_data/Build/Products/Release/Jort.app"', build)
        self.assertEqual(build.count('-derivedDataPath "$derived_data"'), 1)
        self.assertNotIn('$JORT_ROOT/.build/Build/Products/Release/Jort.app', build)
        self.assertIn('if [[ "$identity" != "-" ]]; then\n'
                      '  # The profile is deliberately embedded after the build', build)
        self.assertIn('overrides+=("CODE_SIGNING_ALLOWED=NO")', build)
        for script in ('sign-javascript-broker.sh', 'sign-javascript-worker.sh'):
            with self.subTest(script=script):
                result = subprocess.run(
                    ['bash', str(ROOT / 'scripts' / script)],
                    env=dict(os.environ, CODE_SIGNING_ALLOWED='NO'), capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Skipping', result.stdout)

    def test_release_staging_disables_xcode_signing_for_build_and_settings(self):
        (self.root / 'dist').mkdir()
        args = SimpleNamespace(fail_at=None, architectures=['arm64'], team_id=TEAM)
        calls = []

        def runner(command, **kwargs):
            calls.append(command)
            return b'[]' if '-showBuildSettings' in command else b''

        with patch.object(release, 'ROOT', self.root), \
                patch.object(release, 'preflight', return_value='fixture Xcode') as preflight, \
                patch('validate.xcode_lock', return_value=nullcontext()), \
                patch.object(release.shutil, 'copytree', side_effect=ValueError('fixture build complete')), \
                patch('builtins.print'):
            with self.assertRaisesRegex(ValueError, 'fixture build complete'):
                release.release(args, runner)
        preflight.assert_called_once_with(args, runner)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][-1], 'build')
        self.assertIn('-showBuildSettings', calls[1])
        for command in calls:
            self.assertIn('CODE_SIGNING_ALLOWED=NO', command)
            self.assertFalse(any(argument.startswith('CODE_SIGN_IDENTITY=') for argument in command))
            self.assertIn('JORT_CREDENTIAL_ENVIRONMENT=production', command)
            self.assertIn('JORT_APP_ENTITLEMENTS=Configuration/JortProduction.entitlements', command)

    def test_graph_cases(self):
        policy = json.loads((ROOT / 'Configuration/release-policy.json').read_text())
        for case in json.loads((ROOT / 'Tests/Packaging/graph-cases.json').read_text()):
            with self.subTest(case=case['name']):
                project = manifests.read_project()
                mutation = case['mutation']
                if mutation == 'remove-worker':
                    del project['targets']['JortJavaScriptWorker']
                elif mutation == 'remove-broker':
                    del project['targets']['JortJavaScriptBroker']
                elif mutation == 'duplicate-embedding':
                    project['targets']['Jort']['dependencies'].append({'target': 'JortJavaScriptBroker', 'embed': True})
                elif mutation in {'stale-engine', 'extra-helper'}:
                    name = 'JortJavaScript' if mutation == 'stale-engine' else 'Surprise'
                    project['targets'][name] = {'type': 'framework'}
                    project['targets']['Jort']['dependencies'].append({'target': name, 'embed': True})
                elif mutation == 'remove-framework':
                    project['targets']['Jort']['dependencies'] = [dep for dep in project['targets']['Jort']['dependencies'] if dep.get('target') != 'JortDocument']
                if case['valid']:
                    manifests.shipping_graph(project, policy)
                else:
                    with self.assertRaises(ValueError):
                        manifests.shipping_graph(project, policy)

    def test_worker_is_required_only_inside_its_broker_bundle(self):
        policy = json.loads((ROOT / 'Configuration/release-policy.json').read_text())
        self.assertEqual(policy['requiredDirectories'], [])
        self.assertNotIn('Contents/Helpers', self.manifest['directories'])
        worker = next(item for item in self.manifest['objects'] if item['target'] == 'JortJavaScriptWorker')
        self.assertEqual(worker['path'],
                         'Contents/XPCServices/JortJavaScriptBroker.xpc/Contents/Helpers/JortJavaScriptWorker')
        self.assertTrue((self.app / worker['path']).is_file())

    def test_release_hardened_runtime_applies_to_every_shipping_target(self):
        project = manifests.read_project()
        self.assertEqual(project['settings']['configs']['Release']['ENABLE_HARDENED_RUNTIME'], True)
        policy = json.loads((ROOT / 'Configuration/release-policy.json').read_text())
        for target in manifests.shipping_graph(project, policy):
            with self.subTest(target=target):
                target_release = project['targets'][target].get('settings', {}).get('configs', {}).get('Release', {})
                self.assertNotEqual(target_release.get('ENABLE_HARDENED_RUNTIME'), False)

    def test_every_required_file_and_link(self):
        for relative in list(self.manifest['files']) + list(self.manifest['symlinks']) + list(self.manifest['directories']):
            with self.subTest(path=relative):
                path = self.app / relative
                held = self.root / 'held'; path.rename(held)
                try:
                    with self.assertRaises(ValueError):
                        self.validate()
                finally:
                    held.rename(path)

    def test_manifest_rejects_duplicates_paths_schema_containment(self):
        for field in ('identifier', 'path', 'executable'):
            altered = copy.deepcopy(self.manifest)
            altered['objects'][1][field] = altered['objects'][0][field]
            with self.assertRaises(ValueError):
                manifests.validate_manifest(altered)
        for path in ('../evil', '/tmp/evil', 'a/../evil', './evil'):
            altered = copy.deepcopy(self.manifest); altered['files'][path] = {'kind': 'resource', 'mode': 420}
            with self.assertRaises(ValueError):
                manifests.validate_manifest(altered)
        altered = copy.deepcopy(self.manifest); altered['schemaVersion'] = 999
        with self.assertRaises(ValueError):
            manifests.validate_manifest(altered)
        altered = copy.deepcopy(self.manifest)
        next(obj for obj in altered['objects'] if obj['role'] == 'worker')['parent'] = 'Jort'
        with self.assertRaises(ValueError):
            manifests.validate_manifest(altered)

    def test_schema_rejects_unknown_fields_bad_types_and_metadata(self):
        for key, value in [('unexpected', True), ('production', 'yes'), ('version', 'invalid'),
                           ('build', '3.1'), ('sourceRevision', 'head'), ('policySHA256', 'not-a-hash')]:
            altered = copy.deepcopy(self.manifest)
            altered[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                manifests.validate_manifest(altered)
        altered = copy.deepcopy(self.manifest)
        altered['objects'][0]['unexpected'] = True
        with self.assertRaises(ValueError):
            manifests.validate_manifest(altered)
        with self.assertRaisesRegex(ValueError, 'unsupported manifest schema keyword'):
            manifests.validate_schema({}, {'unreviewedKeyword': True})

    def test_entitlement_widening_is_rejected_before_any_signature(self):
        for role, key in [('app', 'com.apple.security.app-sandbox'), ('app', 'com.apple.security.cs.allow-jit'),
                          ('broker', 'keychain-access-groups'), ('worker', 'com.apple.security.network.client'),
                          ('framework', 'com.apple.security.cs.disable-library-validation')]:
            altered = copy.deepcopy(self.manifest)
            item = next(item for item in altered['objects'] if item['role'] == role)
            item['entitlements'][key] = [TEAM + '.credentials'] if key == 'keychain-access-groups' else True
            calls = []
            with self.subTest(role=role, key=key), self.assertRaises(ValueError):
                signing.sign_all(self.app, altered, TEAM, IDENTITY, calls.append, self.root)
            self.assertEqual(calls, [])
        altered = copy.deepcopy(self.manifest)
        altered['objects'][0]['entitlementSHA256'] = '0' * 64
        with self.assertRaises(ValueError):
            manifests.validate_manifest(altered)
        altered = copy.deepcopy(self.manifest)
        next(item for item in altered['objects'] if item['role'] == 'broker')['entitlements']['com.apple.security.app-sandbox'] = 1
        with self.assertRaises(ValueError):
            manifests.validate_manifest(altered)
        policy = json.loads((ROOT / 'Configuration/release-policy.json').read_text())
        policy['roles']['Jort']['entitlements']['com.apple.security.app-sandbox'] = True
        with self.assertRaisesRegex(ValueError, 'policy widened'):
            manifests.validate_entitlement_sources(ROOT, policy)
        # Changing both editable policy and source cannot authorize a new capability.
        source_root = self.root / 'source'; source_root.mkdir()
        shutil.copytree(ROOT / 'Configuration', source_root / 'Configuration')
        source = source_root / 'Configuration/JortJavaScriptBroker.entitlements'
        source.write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True,
                                          'com.apple.security.cs.allow-jit': True}))
        with self.assertRaisesRegex(ValueError, 'source drift'):
            manifests.validate_entitlement_sources(source_root, json.loads((ROOT / 'Configuration/release-policy.json').read_text()))
        altered = copy.deepcopy(self.manifest)
        broker = next(item for item in altered['objects'] if item['role'] == 'broker')
        broker['entitlementSHA256'] = manifests.digest(source)
        with patch.object(manifests, 'ROOT', source_root), self.assertRaisesRegex(ValueError, 'source capabilities drift'):
            manifests.validate_manifest(altered)

    def test_secret_input_scan_is_bounded_and_never_reports_match_or_path(self):
        secrets = [b'-----BEGIN ' + b'PRIVATE KEY-----', b'sk-or-v1-' + b'a' * 64,
                   b'ghp_' + b'A' * 36, b'AKIA' + b'B' * 16,
                   b'Bearer eyJ' + b'C' * 20 + b'.' + b'D' * 20 + b'.' + b'E' * 20]
        for secret in secrets:
            path = self.root / 'sensitive-user-input.txt'
            path.write_bytes(secret)
            with self.subTest(kind=secret[:5]), self.assertRaises(ValueError) as error:
                release_inputs.scan_repository(self.root, b'sensitive-user-input.txt\0')
            self.assertNotIn(secret.decode(), str(error.exception))
            self.assertNotIn(str(path), str(error.exception))
            altered = copy.deepcopy(self.manifest)
            altered['toolchain'] = secret.decode()
            with self.assertRaises(ValueError):
                manifests.validate_manifest(altered)
        release_inputs.scan_bytes(b'api_key = "example"\ncertificateSHA1=' + b'A' * 40)
        release_inputs.scan_manifest(self.manifest)
        altered = copy.deepcopy(self.manifest)
        altered['objects'][0]['infoValues']['apiKey'] = 'opaque credential'
        with self.assertRaisesRegex(ValueError, 'secret-looking manifest field'):
            manifests.validate_manifest(altered)
        with patch.object(release_inputs, 'MAX_FILE_BYTES', 8), self.assertRaises(ValueError):
            release_inputs.scan_repository(self.root, b'sensitive-user-input.txt\0')
        with self.assertRaises(ValueError):
            release_inputs.scan_repository(self.root, b'../escape\0')

    def test_current_repository_inputs_have_no_scanner_false_positives(self):
        inputs = subprocess.run(['git', 'ls-files', '-co', '--exclude-standard', '-z'],
                                cwd=ROOT, capture_output=True, check=True).stdout
        release_inputs.scan_repository(ROOT, inputs)

    def test_preflight_rejects_version_drift_before_build_or_credentials(self):
        settings = copy.deepcopy(self.settings)
        settings[0]['buildSettings']['CURRENT_PROJECT_VERSION'] = '99'
        args = SimpleNamespace(revision='a' * 40, identity=IDENTITY, team_id=TEAM,
                               notary_profile='fixture', provisioning_profile=self.root / 'profile',
                               architectures=['arm64'], candidate=True)
        calls = []
        def runner(command, **kwargs):
            calls.append(command)
            if command[:3] == ['git', 'rev-parse', 'HEAD']:
                return args.revision.encode()
            if '-showBuildSettings' in command:
                return json.dumps(settings).encode()
            if command == ['xcodebuild', '-version']:
                return b'Xcode 26.0'
            return b''
        with patch.object(release, 'inspect_profile'), patch('validate.xcode_lock', return_value=nullcontext()):
            with self.assertRaisesRegex(ValueError, 'incoherent'):
                release.preflight(args, runner, ROOT)
        self.assertFalse(any(command[-1] == 'build' or command[0] in {'security', 'xcrun'} for command in calls))
    def test_unexpected_bytes_modes_links_and_resources(self):
        for relative, contents in [('Contents/extra', b'bytes'), ('Contents/Resources/evil', b'\xcf\xfa\xed\xfe'), ('Contents/Frameworks/JortJavaScript.framework/evil', b'engine')]:
            with self.subTest(path=relative):
                path = self.app / relative; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(contents)
                with self.assertRaises(ValueError):
                    self.validate()
                path.unlink()
                if path.parent.name == 'JortJavaScript.framework':
                    path.parent.rmdir()
        executable = self.app / self.manifest['objects'][0]['executable']
        executable.chmod(0o644)
        with self.assertRaises(ValueError):
            self.validate()
        executable.chmod(0o755)
        icon = self.app / 'Contents/Resources/AppIcon.icns'
        original = icon.read_bytes(); icon.write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            self.validate()
        icon.write_bytes(original)
        link = self.app / next(iter(self.manifest['symlinks']))
        target = os.readlink(link); link.unlink(); link.symlink_to('/tmp')
        with self.assertRaises(ValueError):
            self.validate()
        link.unlink(); link.symlink_to(target)

    def test_macho_closure_failures(self):
        original = copy.deepcopy(self.inspections)
        cases = [('architecture', None), ('dependency', '/usr/local/lib/evil.dylib'),
                 ('dependency', '@rpath/missing.framework/missing'), ('runpath', '/tmp'), ('engine', None)]
        for case, value in cases:
            with self.subTest(case=case, value=value):
                self.inspections.clear(); self.inspections.update(copy.deepcopy(original))
                target = self.inspections['Jort']
                if case == 'architecture':
                    target['architectures'] = ['x86_64']
                elif case == 'dependency':
                    target['slices']['arm64']['dependencies'].append(value)
                elif case == 'runpath':
                    target['slices']['arm64']['rpaths'].append(value)
                else:
                    target['slices']['arm64']['engine'] = True
                with self.assertRaises(ValueError):
                    self.validate()

    def test_signing_plan_and_negative_facts(self):
        plan = signing.signing_plan(self.manifest)
        names = [item['target'] for item in plan]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(names[-1], 'Jort')
        self.assertLess(names.index('JortJavaScriptWorker'), names.index('JortJavaScriptBroker'))
        item = self.manifest['objects'][0]
        facts = {'identifier': item['identifier'], 'teamID': TEAM, 'runtime': True, 'timestamp': True,
                 'developerID': True, 'validCertificate': True, 'certificateSHA1': IDENTITY,
                 'entitlements': item['entitlements'], 'requirementSatisfied': True, 'strictVerification': True}
        signing.validate_signature_facts(item, facts, TEAM, IDENTITY)
        for field, bad in [('identifier', 'wrong'), ('teamID', 'OTHER12345'), ('runtime', False), ('timestamp', False),
                           ('developerID', False), ('validCertificate', False), ('certificateSHA1', 'B' * 40),
                           ('entitlements', {'com.apple.security.cs.allow-jit': True}), ('strictVerification', False), ('requirementSatisfied', False)]:
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    signing.validate_signature_facts(item, dict(facts, **{field: bad}), TEAM, IDENTITY)

    def test_signature_verification_passes_inline_designated_requirement(self):
        calls = []

        def runner(command):
            calls.append(command)
            raise ValueError('fixture requirement verification')

        for item in self.manifest['objects']:
            with self.subTest(target=item['target']), patch.object(signing, 'verify_peer_requirements'):
                with self.assertRaisesRegex(ValueError, 'fixture requirement verification'):
                    signing.verify_object(self.app, item, TEAM, IDENTITY, runner, self.root)
                command = calls[-1]
                requirements = [argument for argument in command if argument.startswith('-R=')]
                self.assertEqual(requirements, ['-R=' + signing.designated_requirement(item, TEAM)])
                self.assertNotIn('-R', command)
                self.assertEqual(command[-1], str(self.app / item['path']))
                self.assertIn('--strict', command)

    def test_signature_verification_passes_inline_certificate_prefix(self):
        calls = []
        for item in self.manifest['objects']:
            def runner(command, **kwargs):
                calls.append(command)
                if any(argument.startswith('--extract-certificates') for argument in command):
                    raise ValueError('fixture certificate extraction')
                if '-r-' in command:
                    return signing.designated_requirement(item, TEAM).encode()
                if '--entitlements' in command:
                    return plistlib.dumps(item['entitlements'])
                return b''

            with self.subTest(target=item['target']), patch.object(signing, 'verify_peer_requirements'):
                with self.assertRaisesRegex(ValueError, 'fixture certificate extraction'):
                    signing.verify_object(self.app, item, TEAM, IDENTITY, runner, self.root)
                command = calls[-1]
                prefix = str(self.root / (item['target'] + '-certificate-'))
                self.assertEqual(command, ['codesign', '--display', '--extract-certificates=' + prefix,
                                           str(self.app / item['path'])])
                self.assertNotIn('--extract-certificates', command)

    def test_compiled_peer_requirements(self):
        def binary(markers):
            payload = b'\0'.join(value.encode('ascii') for value in markers) + b'\0'
            header = struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 1, 152, 0, 0)
            segment = struct.pack('<II16sQQQQIIII', 0x19, 152, b'__TEXT', 0, 4096,
                                  0, 184 + len(payload), 5, 5, 1, 0)
            section = struct.pack('<16s16sQQIIIIIIII', b'__jort_peer', b'__TEXT', 184,
                                  len(payload), 184, 0, 0, 0, 0, 0, 0, 0)
            return header + segment + section + payload
        path = self.root / 'peer-binary'
        for item in self.manifest['objects']:
            expected = ['JORT_PEER_V1|' + peer['edge'] + '|' + peer['requirementTemplate']
                        for peer in item['peerRequirements']]
            path.write_bytes(binary(expected))
            signing.verify_peer_requirements(path, item)
            if not expected:
                path.write_bytes(binary(['JORT_PEER_V1|unapproved|anchor trusted']))
                with self.assertRaises(ValueError):
                    signing.verify_peer_requirements(path, item)
                continue
            path.write_bytes(struct.pack('<8I', 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0)
                             + '\0'.join(expected).encode('ascii') + b'\0')
            with self.assertRaises(ValueError):
                signing.verify_peer_requirements(path, item)
            variants = [[], expected + expected, [value.replace('anchor apple generic', 'anchor trusted') for value in expected],
                        [value.replace('dev.jort.editor', 'dev.other.editor') for value in expected],
                        [value.replace('%@', 'OTHER12345') for value in expected],
                        [value.replace('certificate leaf[subject.OU]', 'certificate root[subject.OU]') for value in expected]]
            for markers in variants:
                with self.subTest(target=item['target'], markers=markers):
                    path.write_bytes(binary(markers))
                    with self.assertRaises(ValueError):
                        signing.verify_peer_requirements(path, item)
            # A correct first slice cannot hide a wrong second architecture.
            first, second = binary(expected), binary([])
            fat = struct.pack('>II', 0xCAFEBABE, 2)
            fat += struct.pack('>5I', 0x0100000C, 0, 48, len(first), 0)
            fat += struct.pack('>5I', 0x01000007, 0, 48 + len(first), len(second), 0)
            path.write_bytes(fat + first + second)
            with self.assertRaises(ValueError):
                signing.verify_peer_requirements(path, dict(item, architectures=['arm64', 'x86_64']))

    def test_manifest_rejects_runtime_peer_policy_drift(self):
        for field, value in [('teamRelation', 'any'), ('requirementTemplate', 'anchor trusted'),
                             ('peerTarget', 'JortJavaScriptWorker')]:
            altered = copy.deepcopy(self.manifest)
            client = next(item for item in altered['objects'] if item['target'] == 'JortJavaScriptClient')
            client['peerRequirements'][0][field] = value
            with self.assertRaises(ValueError):
                manifests.validate_manifest(altered)
        altered = copy.deepcopy(self.manifest)
        next(item for item in altered['objects'] if item['target'] == 'JortJavaScriptBroker')['peerRequirements'] = []
        with self.assertRaises(ValueError):
            manifests.validate_manifest(altered)

    def test_sealed_inventory_detects_mutation(self):
        before = self.validate()
        for section, key, value in [('inventory', 'Contents/Info.plist', {'sha256': 'changed'}), ('payloads', 'Jort', ['changed'])]:
            after = copy.deepcopy(before); after[section][key] = value
            with self.assertRaises(ValueError):
                validation.compare_inventory(before, after, self.manifest)
            with self.assertRaises(ValueError):
                validation.compare_inventory(before, after, self.manifest, signing=True)

    def test_local_validation_and_swap_failure_preserve_destination(self):
        destination = self.root / 'dist/Jort.app'
        validator = lambda path, manifest: validation.validate_bundle(path, manifest, self.inspector)
        package.package(self.app, destination, self.manifest, validator)
        (destination / 'last-good').write_text('preserve')
        with self.assertRaises(OSError):
            package.package(self.app, destination, self.manifest, validator, lambda *_: (_ for _ in ()).throw(OSError('swap injected')))
        self.assertTrue((destination / 'last-good').exists())
        (self.app / 'Contents/Resources/AppIcon.icns').unlink()
        with self.assertRaises(ValueError):
            package.package(self.app, destination, self.manifest, validator)
        self.assertTrue((destination / 'last-good').exists())

    def test_failure_boundaries_and_atomic_publication(self):
        prior = self.root / 'Jort-prior'; prior.mkdir(); (prior / 'verified').write_text('good')
        stage = self.root / '.release-test'; stage.mkdir()
        image = stage / 'Jort.dmg'; image.write_bytes(b'final-image')
        record = stage / 'verification.json'; record.write_bytes(manifests.canonical({'artifact': release.artifact_facts(image)}))
        destination = self.root / 'Jort-version'
        with patch('release.os.rename', side_effect=OSError('publish injected')):
            with self.assertRaises(OSError):
                release.publish(stage, image, record, destination)
        self.assertFalse(destination.exists())
        shutil.rmtree(stage / 'verified')
        release.publish(stage, image, record, destination)
        self.assertEqual((destination / image.name).read_bytes(), b'final-image')
        with self.assertRaises(ValueError):
            release.publish(stage, image, record, destination)
        self.assertEqual((prior / 'verified').read_text(), 'good')

    def test_each_pipeline_failure_preserves_publication_and_detaches_mount(self):
        dist = self.root / 'dist'; dist.mkdir()
        prior = dist / 'prior'; prior.mkdir(); (prior / 'verified').write_text('good')
        manifest = copy.deepcopy(self.manifest)
        manifest['provisioningProfile'] = {'signingCertificateSHA1': IDENTITY}
        for failure in release.BOUNDARIES:
            calls = []
            args = SimpleNamespace(fail_at=failure, architectures=['arm64'], team_id=TEAM,
                                   identity=IDENTITY, revision='a' * 40, candidate=False,
                                   notary_profile='fixture', provisioning_profile=self.root / 'profile')
            existing = set(dist.iterdir())
            def runner(command, **kwargs):
                calls.append(command)
                if command[0] == 'xcodebuild' and command[-1] == 'build':
                    derived = Path(command[command.index('-derivedDataPath') + 1])
                    shutil.copytree(self.app, derived / 'Build/Products/Release/Jort.app', symlinks=True)
                if '-showBuildSettings' in command:
                    return json.dumps(self.settings).encode()
                if command[:2] == ['hdiutil', 'create']:
                    Path(command[-1]).write_bytes(b'image')
                if command[:3] == ['xcrun', 'notarytool', 'submit']:
                    return json.dumps({'id': '12345678-1234-1234-1234-123456789abc', 'status': 'Accepted'}).encode()
                if command[:2] == ['hdiutil', 'attach']:
                    mount = Path(command[command.index('-mountpoint') + 1])
                    shutil.copytree(self.app, mount / 'Jort.app', symlinks=True)
                    (mount / 'Applications').symlink_to('/Applications')
                    return plistlib.dumps({'system-entities': [{'mount-point': str(mount)}]})
                return b''
            with self.subTest(stage=failure), patch.object(release, 'ROOT', self.root), \
                    patch.object(release, 'preflight', return_value='Xcode fixture'), \
                    patch('validate.xcode_lock', return_value=nullcontext()), \
                    patch.object(release, 'embed_profile'), patch.object(release, 'generate', return_value=manifest), \
                    patch.object(release, 'validate_bundle', return_value={}), \
                    patch.object(release, 'compare_inventory'), \
                    patch.object(release, 'sign_all', return_value=[]), patch.object(release, 'verify_all'), \
                    patch.object(release, 'publish', wraps=release.publish) as publish, patch('builtins.print') as output:
                with self.assertRaisesRegex(ValueError, 'injected failure at ' + failure):
                    release.release(args, runner)
                publish.assert_not_called()
                diagnostics = ' '.join(str(call) for call in output.call_args_list)
                self.assertNotIn(str(self.root), diagnostics)
            new_stages = set(dist.iterdir()) - existing
            self.assertEqual(len(new_stages), 0 if failure == 'preflight' else 1)
            for stage in new_stages:
                self.assertEqual(json.loads((stage / 'failure.json').read_text()),
                                 {'schemaVersion': 1, 'stage': failure, 'status': 'failed', 'published': False})
                self.assertFalse((stage / 'verified').exists())
            self.assertEqual((prior / 'verified').read_text(), 'good')
            self.assertFalse((dist / f'Jort-{manifest["version"]}-{manifest["build"]}-macos').exists())
            mounted = any(command[:2] == ['hdiutil', 'attach'] for command in calls)
            self.assertEqual(any(command[:2] == ['hdiutil', 'detach'] for command in calls), mounted)

    def test_notary_failure_diagnostics_are_allowlisted_and_bounded(self):
        submission = '12345678-1234-1234-1234-123456789abc'
        calls = []
        raw_secret = 'DO-NOT-PERSIST-notary-token'
        payload = {
            'issues': [
                {'severity': 'error', 'code': 'MALFORMED',
                 'message': 'bad signature ' + ('x' * 400),
                 'path': '/private/' + raw_secret, 'url': 'https://example.invalid/' + raw_secret,
                 'unexpected': raw_secret},
                'not an issue',
                {'severity': 'error', 'code': 'DETAIL',
                 'message': 'inspect /Users/alice/Jort.app at https://example.invalid/log for alice@example.com '
                            'with token=' + raw_secret + ' and notary-profile=jort-release; generic signature mismatch'},
            ] + [{'severity': 'warning', 'code': 'W' + str(index), 'message': 'fixture'} for index in range(25)],
            'authentication': raw_secret,
        }

        def runner(args):
            calls.append(args)
            return json.dumps(payload).encode()

        evidence = release.notary_diagnostics(submission, 'Rejected', 'fixture-profile', runner)
        self.assertEqual(calls, [['xcrun', 'notarytool', 'log', submission, '--keychain-profile', 'fixture-profile', '--output-format', 'json']])
        self.assertEqual(evidence['issueCount'], 20)
        self.assertEqual(len(evidence['issues']), 20)
        self.assertEqual(evidence['issues'][0], {'severity': 'error', 'code': 'MALFORMED',
                                                  'message': 'bad signature ' + ('x' * 226)})
        self.assertEqual(evidence['issues'][1], {
            'severity': 'error', 'code': 'DETAIL',
            'message': 'inspect [redacted-path] at [redacted-url] for [redacted-email] with '
                       '[redacted-value] and [redacted-value] generic signature mismatch'})
        serialized = manifests.canonical(evidence).decode()
        self.assertNotIn(raw_secret, serialized)
        self.assertNotIn('/Users/alice/Jort.app', serialized)
        self.assertNotIn('example.invalid/log', serialized)
        self.assertNotIn('alice@example.com', serialized)
        self.assertNotIn('jort-release', serialized)
        self.assertNotIn('/private/', serialized)
        self.assertNotIn('https://example.invalid/', serialized)
        self.assertTrue(evidence['available'])

    def test_notary_failure_diagnostics_do_not_store_retrieval_failure(self):
        submission = '12345678-1234-1234-1234-123456789abc'

        def runner(_):
            raise ValueError('notary output with DO-NOT-PERSIST-token')

        evidence = release.notary_diagnostics(submission, 'Invalid', 'fixture-profile', runner)
        self.assertEqual(evidence, {'schemaVersion': 1, 'id': submission, 'status': 'Invalid',
                                    'available': False, 'issueCount': 0, 'issues': []})
        with self.assertRaises(ValueError):
            release.notary_diagnostics(submission, 'Accepted', 'fixture-profile', runner)

    def test_notary_nonterminal_diagnostics_skip_log_and_retain_only_fixed_metadata(self):
        submission = '12345678-1234-1234-1234-123456789abc'

        def runner(_):
            raise AssertionError('nonterminal status must not retrieve a log')

        for status in ('In Progress', 'Unavailable'):
            with self.subTest(status=status):
                evidence = release.notary_diagnostics(
                    submission, status, 'profile-DO-NOT-PERSIST', runner)
                self.assertEqual(evidence, {
                    'schemaVersion': 1, 'id': submission, 'status': status,
                    'available': False, 'issueCount': 0, 'issues': []})
                serialized = manifests.canonical(evidence).decode()
                self.assertNotIn('profile-DO-NOT-PERSIST', serialized)
                self.assertNotIn('not retrieve', serialized)


if __name__ == '__main__':
    unittest.main(verbosity=1)
