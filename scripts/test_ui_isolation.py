"""Mocked tests: no Xcode builds, application launches, or real signing."""
import copy
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'prepare_ui_tests', Path(__file__).with_name('prepare-ui-tests.py'))
prep = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prep)


class UIIsolationTests(unittest.TestCase):
    def test_launcher_keeps_focused_selection_narrow(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / 'arguments'
            xcode = root / 'xcodebuild'
            xcode.write_text('#!/bin/sh\nprintf "%s\\n" __COMMAND__ "$@" >> "$JORT_TEST_ARGUMENT_LOG"\n')
            xcode.chmod(0o700)
            python = root / 'python3'
            python.write_text('#!/bin/sh\nprintf "%s\\n" /private/tmp/mock.xctestrun\n')
            python.chmod(0o700)
            environment = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'],
                               JORT_TEST_ARGUMENT_LOG=str(log))
            launcher = Path(__file__).with_name('run-isolated-ui-tests.sh')
            narrow = '-only-testing:JortUITests/JortUITests/testExample'
            for extra, expected in [([], '-only-testing:JortUITests'), (['--', narrow], narrow)]:
                log.write_text('')
                subprocess.run(['/bin/bash', str(launcher), *extra], env=environment,
                               check=True, capture_output=True)
                commands = log.read_text().split('__COMMAND__\n')[1:]
                self.assertEqual(len(commands), 2)
                for command in commands:
                    selections = [argument for argument in command.splitlines()
                                  if argument.startswith('-only-testing:')]
                    self.assertEqual(selections, [expected])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.products = self.root / '.build-ui/Build/Products'
        self.app = self.products / 'Debug/Jort.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/Jort').write_bytes(b'mocked executable')
        nested = self.app / 'Contents/XPCServices/Broker.xpc/Contents'
        nested.mkdir(parents=True)
        (nested / 'payload').write_bytes(b'nested payload')
        self.info = {'CFBundleIdentifier': prep.PRODUCTION_ID, 'CFBundleExecutable': 'Jort',
                     'JortCredentialEnvironment': 'development', 'JortExpectedTeamIdentifier': '',
                     'CFBundleVersion': '7', 'CFBundleName': 'Jort'}
        prep.write_plist(self.app / 'Contents/Info.plist', self.info)
        self.record = {'BlueprintName': 'JortUITests',
                       'TestHostPath': '__TESTROOT__/Debug/JortUITests-Runner.app',
                       'UITargetAppPath': '__TESTROOT__/Debug/Jort.app',
                       'UITargetAppBundleIdentifier': prep.PRODUCTION_ID,
                       'EnvironmentVariables': {'KEEP_RUNNER': 'yes'},
                       'UITargetAppEnvironmentVariables': {'KEEP_APP': 'yes'}}
        self.document = {'__xctestrun_metadata__': {'FormatVersion': 2},
                         'TestConfigurations': [{'TestTargets': [self.record,
                             {'BlueprintName': 'OtherTests', 'KEEP': 'unchanged'}]}]}
        self.run = self.products / 'tests.xctestrun'
        prep.write_plist(self.run, self.document)
        self.details = b'Identifier=dev.jort.editor\nSignature=adhoc\nTeamIdentifier=not set\n'
        self.entitlements = dict(prep.LOCAL_ENTITLEMENTS)
        self.commands = []
        for name, replacement in [('ROOT', self.root), ('command', self.command),
                                  ('payload', lambda app: ['mocked-payload'])]:
            context = patch.object(prep, name, replacement)
            context.start()
            self.addCleanup(context.stop)

    def command(self, arguments):
        self.commands.append(arguments)
        if '--entitlements' in arguments and '--display' in arguments:
            return plistlib.dumps(self.entitlements)
        if '--display' in arguments:
            return self.details
        return b''

    def save_run(self):
        prep.write_plist(self.run, self.document)

    def prepare(self, **kwargs):
        return prep.prepare(self.products, **kwargs)

    def test_unique_identity_and_exact_rewrite(self):
        original = prep.inventory(self.app)
        first = self.prepare()
        second = self.prepare(kind='packaged')
        ids = []
        for output, kind in [(first, 'debug'), (second, 'packaged')]:
            document = prep.read_plist(output)
            record = document['TestConfigurations'][0]['TestTargets'][0]
            app = Path(record['UITargetAppPath'])
            identifier = record['UITargetAppBundleIdentifier']
            ids.append(identifier)
            self.assertTrue(identifier.startswith('dev.jort.editor.uitests.' + kind + '.'))
            self.assertTrue(app.is_absolute())
            self.assertNotEqual(app, self.app)
            info = prep.read_plist(app / 'Contents/Info.plist')
            expected = dict(self.info, CFBundleIdentifier=identifier, JortUITestIsolation=True,
                            CFBundleDisplayName='Jort UI Tests' if kind == 'debug' else 'Jort Packaged UI Tests')
            self.assertEqual(info, expected)
            runner = record['EnvironmentVariables']
            self.assertEqual(runner['JORT_UI_TEST_APP_PATH'], str(app))
            self.assertEqual(runner['JORT_UI_TEST_APP_ID'], identifier)
            self.assertEqual(runner['KEEP_RUNNER'], 'yes')
            environment = record['UITargetAppEnvironmentVariables']
            store = Path(environment['JORT_DATA_DIRECTORY'])
            self.addCleanup(shutil.rmtree, store)
            self.assertTrue(store.is_dir())
            self.assertTrue(store.is_relative_to(Path('/private/tmp').resolve()))
            self.assertFalse(store.is_relative_to(self.products))
            self.assertTrue(environment['JORT_UI_TEST_ISOLATION_NONCE'])
            self.assertEqual(environment['KEEP_APP'], 'yes')
            self.assertNotIn('JORT_UI_TEST_APP_PATH', environment)
            self.assertEqual(document['TestConfigurations'][0]['TestTargets'][1],
                             self.document['TestConfigurations'][0]['TestTargets'][1])
            self.assertEqual(prep.derivative_inventory(prep.inventory(app)),
                             prep.derivative_inventory(original))
        self.assertNotEqual(*ids)
        self.assertEqual(prep.inventory(self.app), original)
        self.assertEqual(prep.read_plist(self.run), self.document)
        signings = [args for args in self.commands if '--force' in args]
        self.assertEqual(len(signings), 2)
        registrations = [args for args in self.commands if args[0].endswith('/lsregister')]
        self.assertEqual([args[-1] for args in registrations],
                         [str(output.parent / 'Jort.app') for output in (first, second)])
        for args in signings:
            self.assertNotIn('--deep', args)
            self.assertEqual(args[args.index('--identifier') + 1], prep.PRODUCTION_ID)
            self.assertEqual(args[args.index('--options') + 1], 'runtime')

    def test_relocated_testroot_references(self):
        self.record['TestBundlePath'] = '__TESTHOST__/Contents/PlugIns/JortUITests.xctest'
        self.record['DependentProductPaths'] = ['__TESTROOT__/Debug/Dependency.framework']
        self.document['ExtraReferences'] = {'nested': [
            {'__TESTROOT__/map-key': '__TESTROOT__/Debug/Product'},
            '__TESTROOT__/one:__TESTROOT__/two', '__TESTHOST__/keep', 7, True]}
        self.save_run()
        output = self.prepare()
        document = prep.read_plist(output)
        record = document['TestConfigurations'][0]['TestTargets'][0]
        self.addCleanup(shutil.rmtree, record['UITargetAppEnvironmentVariables']['JORT_DATA_DIRECTORY'])
        self.assertEqual(record['TestHostPath'], str(self.products / 'Debug/JortUITests-Runner.app'))
        self.assertEqual(record['TestBundlePath'], self.record['TestBundlePath'])
        self.assertEqual(record['DependentProductPaths'], [str(self.products / 'Debug/Dependency.framework')])
        self.assertEqual(document['ExtraReferences']['nested'], [
            {str(self.products / 'map-key'): str(self.products / 'Debug/Product')},
            str(self.products / 'one') + ':' + str(self.products / 'two'),
            '__TESTHOST__/keep', 7, True])
        self.assertNotIn('__TESTROOT__', repr(document))
        self.assertEqual(prep.read_plist(self.run), self.document)

    def test_legacy_target(self):
        self.document = {'JortUITests': copy.deepcopy(self.record), 'OtherTests': {'KEEP': True}}
        self.save_run()
        output = self.prepare()
        self.addCleanup(shutil.rmtree, prep.read_plist(output)['JortUITests'][
            'UITargetAppEnvironmentVariables']['JORT_DATA_DIRECTORY'])
        self.assertNotEqual(prep.read_plist(output)['JortUITests']['UITargetAppBundleIdentifier'],
                            prep.PRODUCTION_ID)

    def test_ambiguous_or_missing_target(self):
        for records in [[], [self.record, copy.deepcopy(self.record)],
                        [dict(self.record, BlueprintName='UnexpectedTests')]]:
            with self.subTest(records=records):
                self.document['TestConfigurations'][0]['TestTargets'] = records
                self.save_run()
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_ambiguous_xctestrun(self):
        prep.write_plist(self.products / 'other.xctestrun', self.document)
        with self.assertRaisesRegex(ValueError, 'exactly one xctestrun'):
            self.prepare()

    def test_missing_launch_fields_and_production_fallback(self):
        for key in ['UITargetAppPath', 'TestHostPath']:
            with self.subTest(key=key):
                record = copy.deepcopy(self.record)
                del record[key]
                self.document['TestConfigurations'][0]['TestTargets'] = [record]
                self.save_run()
                with self.assertRaises(ValueError):
                    self.prepare()
        self.record['UITargetAppBundleIdentifier'] = 'dev.jort.other'
        self.document['TestConfigurations'][0]['TestTargets'] = [self.record]
        self.save_run()
        with self.assertRaisesRegex(ValueError, 'original UI bundle'):
            self.prepare()

    def test_actual_format_one_without_bundle_identifier(self):
        record = copy.deepcopy(self.record)
        del record['UITargetAppBundleIdentifier']
        record.update(UITargetAppCommandLineArguments=[],
                      UITargetAppPerformanceAntipatternCheckerEnabled=True)
        self.document = {'__xctestrun_metadata__': {'FormatVersion': 1}, 'JortUITests': record}
        self.save_run()
        output = self.prepare()
        rewritten = prep.read_plist(output)['JortUITests']
        self.addCleanup(shutil.rmtree, rewritten['UITargetAppEnvironmentVariables']['JORT_DATA_DIRECTORY'])
        self.assertTrue(rewritten['UITargetAppBundleIdentifier'].startswith('dev.jort.editor.uitests.debug.'))
        self.assertEqual(rewritten['UITargetAppCommandLineArguments'], [])
        self.assertIs(rewritten['UITargetAppPerformanceAntipatternCheckerEnabled'], True)
        self.assertEqual(prep.read_plist(self.run), self.document)

    def test_observed_ui_field_types(self):
        for extra in [{'UITargetAppCommandLineArguments': 'invalid'},
                      {'UITargetAppCommandLineArguments': [1]},
                      {'UITargetAppPerformanceAntipatternCheckerEnabled': 1},
                      {'UITargetAppPerformanceAntipatternCheckerEnabled': 'true'}]:
            with self.subTest(extra=extra):
                self.document['TestConfigurations'][0]['TestTargets'] = [dict(self.record, **extra)]
                self.save_run()
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_original_ui_target_path_and_plist_are_always_checked(self):
        for identifier_present in [False, True]:
            record = copy.deepcopy(self.record)
            if not identifier_present:
                del record['UITargetAppBundleIdentifier']
            for path in ['/Applications/Jort.app', str(self.root / 'dist/Jort.app')]:
                with self.subTest(identifier_present=identifier_present, path=path):
                    self.document['TestConfigurations'][0]['TestTargets'] = [dict(record, UITargetAppPath=path)]
                    self.save_run()
                    with self.assertRaises(ValueError):
                        self.prepare()
            self.document['TestConfigurations'][0]['TestTargets'] = [record]
            self.save_run()
            prep.write_plist(self.app / 'Contents/Info.plist', dict(self.info, CFBundleIdentifier='other'))
            with self.assertRaisesRegex(ValueError, 'original UI plist identifier'):
                self.prepare()
            prep.write_plist(self.app / 'Contents/Info.plist', self.info)

    def test_packaged_source(self):
        packaged = self.root / 'dist/Jort.app'
        shutil.copytree(self.app, packaged)
        output = self.prepare(source=packaged, kind='packaged')
        record = prep.read_plist(output)['TestConfigurations'][0]['TestTargets'][0]
        self.addCleanup(shutil.rmtree, record['UITargetAppEnvironmentVariables']['JORT_DATA_DIRECTORY'])
        self.assertNotEqual(record['UITargetAppPath'], str(packaged))
        self.assertEqual(prep.read_plist(packaged / 'Contents/Info.plist'), self.info)

    def test_payload_mutation_is_detected(self):
        with patch.object(prep, 'payload', side_effect=[['original'], ['changed']]):
            with self.assertRaisesRegex(ValueError, 'executable payload'):
                self.prepare()

    def test_unknown_launch_field_and_extra_host(self):
        for extra in [{'UITargetAppUnknown': 'x'}, {'TestHostPath': '/Applications/Jort.app'}]:
            with self.subTest(extra=extra):
                self.document['TestConfigurations'][0]['TestTargets'][0] = dict(self.record, **extra)
                self.save_run()
                with self.assertRaises(ValueError):
                    self.prepare()
        self.document['TestConfigurations'][0]['TestTargets'] = [self.record,
            {'BlueprintName': 'OtherTests', 'TestHostPath': '/Applications/Jort.app'}]
        self.save_run()
        with self.assertRaises(ValueError):
            self.prepare()

    def test_no_identity_or_credential_fallback(self):
        for change in [{'CFBundleIdentifier': 'other'}, {'JortCredentialEnvironment': 'production'},
                       {'JortExpectedTeamIdentifier': 'ABCDEFGHIJ'}]:
            with self.subTest(change=change):
                prep.write_plist(self.app / 'Contents/Info.plist', dict(self.info, **change))
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_reject_signing_and_entitlement_drift(self):
        for details in [b'Identifier=other\nSignature=adhoc\n',
                        b'Identifier=dev.jort.editor\nSignature=adhoc\nTeamIdentifier=ABCDEFGHIJ\n',
                        b'Identifier=dev.jort.editor\nSignature=Developer ID\n']:
            with self.subTest(details=details):
                self.details = details
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_exact_xcode_source_exceptions_are_stripped_and_never_allowed_after_signing(self):
        expanded = dict(prep.LOCAL_ENTITLEMENTS, **prep.XCODE_TEST_EXCEPTIONS)
        self.entitlements = expanded
        self.assertEqual(prep.signing_facts(self.app, allow_test_exceptions=True),
                         prep.LOCAL_ENTITLEMENTS)
        with self.assertRaises(ValueError):
            prep.signing_facts(self.app)
        for change in [{next(iter(prep.XCODE_TEST_EXCEPTIONS)): ['/other']},
                       {'keychain-access-groups': ['secret']}]:
            self.entitlements = dict(expanded, **change)
            with self.assertRaises(ValueError):
                prep.signing_facts(self.app, allow_test_exceptions=True)

    def test_packaged_sources_do_not_accept_xcode_exceptions(self):
        self.entitlements = dict(prep.LOCAL_ENTITLEMENTS, **prep.XCODE_TEST_EXCEPTIONS)
        with self.assertRaises(ValueError):
            self.prepare(kind='packaged')

    def test_reject_entitlement_drift(self):
        self.details = b'Identifier=dev.jort.editor\nSignature=adhoc\n'
        for entitlements in [{}, dict(prep.LOCAL_ENTITLEMENTS, **{'keychain-access-groups': ['secret']}),
                             dict(prep.LOCAL_ENTITLEMENTS, **{'com.apple.security.get-task-allow': 1})]:
            with self.subTest(entitlements=entitlements):
                self.entitlements = entitlements
                with self.assertRaises(ValueError):
                    self.prepare()

    def test_source_symlink_profile_and_outside_repository(self):
        alias = self.products / 'Debug/Alias.app'
        alias.symlink_to(self.app, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.prepare(source=alias)
        with self.assertRaises(ValueError):
            self.prepare(source=Path('/Applications/Jort.app'))
        (self.app / 'Contents/embedded.provisionprofile').write_bytes(b'profile')
        with self.assertRaisesRegex(ValueError, 'profile'):
            self.prepare()

    def test_nested_mutation_is_detected(self):
        original_command = self.command
        def mutate(arguments):
            if '--force' in arguments:
                (Path(arguments[-1]) / 'Contents/XPCServices/Broker.xpc/Contents/payload').write_bytes(b'changed')
            return original_command(arguments)
        with patch.object(prep, 'command', mutate):
            with self.assertRaisesRegex(ValueError, 'derivative content'):
                self.prepare()

    def test_verification_failure_is_closed(self):
        with patch.object(prep, 'command', side_effect=ValueError('signature invalid')):
            with self.assertRaisesRegex(ValueError, 'signature invalid'):
                self.prepare()


if __name__ == '__main__':
    unittest.main()
