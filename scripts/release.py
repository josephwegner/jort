#!/usr/bin/env python3
"""Fail-closed distribution candidate pipeline. Publication is policy-gated."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from release_manifest import (ROOT, canonical, digest, generate, load, require, read_project,
                              resolved_versions, shipping_graph, validate_entitlement_sources)
from release_inputs import scan_repository
from release_signing import sign_all, verify_all
from release_validation import compare_inventory, validate_bundle
from provisioning_profile import embed as embed_profile, inspect as inspect_profile

BOUNDARIES = ('preflight', 'build', 'manifest', 'validate', 'sign', 'post-sign', 'image', 'image-sign', 'notary', 'staple', 'mount', 'assessment', 'publish')
NOTARY_TERMINAL_STATUSES = {'Rejected', 'Invalid'}
NOTARY_FAILURE_STATUSES = NOTARY_TERMINAL_STATUSES | {'In Progress', 'Unavailable'}
NOTARY_DIAGNOSTIC_ISSUES = 20
NOTARY_DIAGNOSTIC_TEXT = 240
NOTARY_SENSITIVE_VALUE = re.compile(
    r'(?i)\b(?:api[ _-]?key|access[ _-]?token|token|auth(?:orization)?|password|passwd|secret|'
    r'notary[ _-]?profile|keychain[ _-]?profile)\b\s*(?:=|:|\s+)\s*(?:"[^"]*"|\'[^\']*\'|\S+)')
NOTARY_URL = re.compile(r'(?i)\b(?:https?|file)://\S+')
NOTARY_EMAIL = re.compile(r'(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b')
NOTARY_PATH = re.compile(r'(?<![A-Z0-9._-])(?:~|/)(?:[A-Z0-9._-]+/)+[A-Z0-9._-]*', re.I)


def _notary_text(value, limit=NOTARY_DIAGNOSTIC_TEXT):
    """Return bounded printable diagnostic text, never an unparsed tool payload."""
    if not isinstance(value, str):
        return None
    text = NOTARY_SENSITIVE_VALUE.sub('[redacted-value]', value)
    text = NOTARY_URL.sub('[redacted-url]', text)
    text = NOTARY_EMAIL.sub('[redacted-email]', text)
    text = NOTARY_PATH.sub('[redacted-path]', text)
    text = ''.join(character if 32 <= ord(character) <= 126 else ' ' for character in text)
    text = ' '.join(text.split())
    return text[:limit] if text else None


def _notary_issue(issue):
    """Project only the reviewed notary-log fields into safe evidence."""
    if not isinstance(issue, dict):
        return None
    result = {}
    severity = _notary_text(issue.get('severity'), 32)
    code = _notary_text(issue.get('code'), 80)
    message = _notary_text(issue.get('message'))
    # These field names are the only data that may move from a service log into
    # retained evidence. In particular, paths, URLs, archive names, and any
    # unrecognized fields can contain machine/account information and are omitted.
    if severity:
        result['severity'] = severity
    if code:
        result['code'] = code
    if message:
        result['message'] = message
    return result or None


def notary_diagnostics(submission, status, profile, runner):
    """Fetch a failed submission's log without retaining raw tool output.

    A retrieval failure is itself non-sensitive evidence; the primary failed
    notarization remains the release failure. Authentication stays in the
    provisioned Keychain profile passed directly to notarytool.
    """
    require(re.fullmatch(r'[0-9a-fA-F-]{36}', submission) is not None, 'missing notarization submission ID')
    require(status in NOTARY_FAILURE_STATUSES, 'notarization status is not a failed submission')
    evidence = {'schemaVersion': 1, 'id': submission, 'status': status, 'available': False, 'issueCount': 0, 'issues': []}
    # A nonterminal or malformed service status has no trustworthy terminal log.
    # Retain only fixed metadata rather than making another service request.
    if status not in NOTARY_TERMINAL_STATUSES:
        return evidence
    try:
        payload = json.loads(runner([
            'xcrun', 'notarytool', 'log', submission, '--keychain-profile', profile,
            '--output-format', 'json']))
    except (ValueError, OSError, json.JSONDecodeError):
        return evidence
    if not isinstance(payload, dict):
        return evidence
    raw_issues = payload.get('issues')
    if not isinstance(raw_issues, list):
        return evidence
    issues = [sanitized for issue in raw_issues if (sanitized := _notary_issue(issue)) is not None]
    evidence.update(available=True, issueCount=min(len(raw_issues), NOTARY_DIAGNOSTIC_ISSUES),
                    issues=issues[:NOTARY_DIAGNOSTIC_ISSUES])
    return evidence


class Runner:
    def __init__(self, root=ROOT):
        self.root = root
        self.environment = {key: os.environ[key] for key in ('HOME', 'USER', 'TMPDIR', 'DEVELOPER_DIR') if key in os.environ}
        self.environment.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin', LC_ALL='C')
        self.environment.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')

    def __call__(self, args, combined=False, timeout=900):
        try:
            result = subprocess.run(args, cwd=self.root, env=self.environment, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise ValueError(Path(args[0]).name + ' timed out') from error
        # Tool output is data, never copied to a log: it can contain credentials,
        # account details, paths, and service error payloads.
        require(result.returncode == 0, Path(args[0]).name + ' failed')
        return result.stdout + result.stderr if combined else result.stdout


def boundary(name, injected=None):
    require(name in BOUNDARIES, 'unknown release boundary')
    if name == injected:
        raise ValueError('injected failure at ' + name)


def release_overrides(args):
    return ['ARCHS=' + ' '.join(sorted(set(args.architectures))), 'ONLY_ACTIVE_ARCH=NO',
            'JORT_CREDENTIAL_ENVIRONMENT=production', 'JORT_PRODUCTION_TEAM_ID=' + args.team_id,
            'JORT_APP_ENTITLEMENTS=Configuration/JortProduction.entitlements',
            'DEVELOPMENT_TEAM=' + args.team_id, 'CODE_SIGNING_ALLOWED=NO']


def settings_command(args):
    return ['xcodebuild', '-project', 'Jort.xcodeproj', '-alltargets',
            '-configuration', 'Release', *release_overrides(args), '-showBuildSettings', '-json']


def preflight(args, runner, root=ROOT):
    require(re.fullmatch(r'[0-9a-f]{40}', args.revision) is not None, 'exact source revision required')
    require(re.fullmatch(r'[0-9A-Fa-f]{40}', args.identity) is not None, 'exact Developer ID certificate SHA-1 required')
    require(re.fullmatch(r'[A-Z0-9]{10}', args.team_id) is not None, 'invalid Team ID')
    require(re.fullmatch(r'[A-Za-z0-9._-]{1,128}', args.notary_profile) is not None, 'invalid Keychain profile selector')
    inspect_profile(args.provisioning_profile, args.team_id, 'production', args.identity)
    require(args.architectures and set(args.architectures) <= {'arm64', 'x86_64'}, 'unsupported release architecture')
    require(runner(['git', 'rev-parse', 'HEAD']).decode().strip() == args.revision, 'source revision mismatch')
    require(not runner(['git', 'status', '--porcelain', '--untracked-files=normal']).strip(), 'release requires a clean source tree')
    scan_repository(root, runner(['git', 'ls-files', '-z']))
    runner(['python3', 'scripts/check-project.py'])
    require(not runner(['git', 'status', '--porcelain', '--untracked-files=normal']).strip(), 'generated project differs from revision')
    policy = json.loads((root / 'Configuration/release-policy.json').read_text())
    validate_entitlement_sources(root, policy)
    require(not policy['communityImportEnabled'], 'community import remains prohibited')
    if not args.candidate:
        require(policy['publicationEnabled'] and all(policy['qualification'].values()), 'publication disabled until signed-release and sandbox qualification evidence is reviewed')
    versions = runner(['xcodebuild', '-version']).decode().strip()
    match = re.search(r'^Xcode (\d+)\.', versions)
    require(match and 16 <= int(match.group(1)) <= 26, 'unsupported Xcode toolchain')
    # Resolve every shipping target before any compilation or staging occurs.
    from validate import xcode_lock
    with xcode_lock():
        resolved_versions(json.loads(runner(settings_command(args))), shipping_graph(read_project(root), policy))
    identities = runner(['security', 'find-identity', '-v', '-p', 'codesigning']).decode()
    matches = re.findall(r'\b' + args.identity.upper() + r' "(Developer ID Application: [^"\n]+)"', identities, re.I)
    require(len(matches) == 1 and matches[0].endswith('(' + args.team_id + ')'), 'Developer ID identity absent, ambiguous, or wrong Team')
    # Authentication happens before spending time on a build. No credentials are
    # accepted in the CLI; only a provisioned Keychain profile is supported.
    history = json.loads(runner(['xcrun', 'notarytool', 'history', '--keychain-profile', args.notary_profile, '--output-format', 'json']))
    require(isinstance(history.get('history'), list), 'notarization profile authentication failed')
    output = root / 'dist'
    require(not output.is_symlink() and output.resolve() == output, 'unsafe distribution root')
    output.mkdir(exist_ok=True)
    return versions


def build_image(app, manifest, output, runner, stage):
    output, stage = Path(output), Path(stage).resolve()
    require(output.parent.resolve() == stage and not output.exists(), 'image output must be new and run-owned')
    validate_bundle(app, manifest)
    image_root = stage / 'image-root'
    image_root.mkdir()
    shutil.copytree(app, image_root / 'Jort.app', symlinks=True)
    os.symlink('/Applications', image_root / 'Applications')
    runner(['hdiutil', 'create', '-volname', 'Install Jort', '-srcfolder', str(image_root), '-format', 'UDZO', '-imagekey', 'zlib-level=9', str(output)])
    require(output.is_file(), 'disk image missing')


def artifact_facts(path):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'invalid artifact path')
    return {'sha256': digest(path), 'bytes': path.stat().st_size}


def publish(stage, image, record, destination):
    """Publish image and evidence as one directory rename; never replace a release."""
    stage, image, record, destination = map(Path, (stage, image, record, destination))
    require(not destination.exists() and not destination.is_symlink(), 'version already published')
    require(destination.parent.resolve() == stage.parent.resolve(), 'publication crossed output boundary')
    facts = json.loads(record.read_text())
    require(facts['artifact'] == artifact_facts(image), 'final artifact/evidence mismatch')
    ready = stage / 'verified'
    ready.mkdir()
    shutil.copy2(image, ready / image.name)
    shutil.copy2(record, ready / record.name)
    require(artifact_facts(ready / image.name) == facts['artifact'], 'publication copy changed')
    for path in ready.iterdir():
        with path.open('rb') as stream:
            os.fsync(stream.fileno())
    os.rename(ready, destination)
    descriptor = os.open(destination.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def release(args, runner=None):
    runner = runner or Runner()
    boundary('preflight', args.fail_at)
    toolchain = preflight(args, runner)
    stage = Path(tempfile.mkdtemp(prefix='.release-', dir=ROOT / 'dist'))
    current = 'build'
    try:
        def step(name):
            nonlocal current
            current = name
            boundary(name, args.fail_at)
            print('Release candidate: ' + name, flush=True)
        step('build')
        overrides = release_overrides(args)
        build = ['xcodebuild', '-project', 'Jort.xcodeproj', '-scheme', 'Jort', '-configuration', 'Release', '-derivedDataPath', str(stage / 'build'), *overrides]
        # Share the same Xcode lock as the canonical validation dispatcher.
        from validate import xcode_lock
        with xcode_lock():
            runner([*build, 'build'], timeout=1800)
            settings = json.loads(runner(settings_command(args)))
        built_app = stage / 'build/Build/Products/Release/Jort.app'
        app = stage / 'Jort.app'
        shutil.copytree(built_app, app, symlinks=True)
        embed_profile(args.provisioning_profile, app)
        step('manifest')
        manifest = generate(ROOT, settings, app, True, args.team_id,
                            {'sourceRevision': args.revision, 'toolchain': toolchain,
                             'xcodegen': runner(['xcodegen', '--version']).decode().strip()},
                            provisioning_profile=args.provisioning_profile,
                            profile_environment='production', signing_identity=args.identity)
        manifest_path = stage / 'manifest.json'
        manifest_path.write_bytes(canonical(manifest)); manifest_path.chmod(0o444)
        manifest_hash = digest(manifest_path)
        step('validate')
        before = validate_bundle(app, manifest)
        (stage / 'pre-sign-inventory.json').write_bytes(canonical(before))
        step('sign')
        require(manifest['provisioningProfile']['signingCertificateSHA1'] == args.identity.upper(),
                'release signing identity does not match provisioning profile')
        signature_evidence = sign_all(app, manifest, args.team_id, args.identity, runner, stage)
        step('post-sign')
        signed = validate_bundle(app, manifest)
        compare_inventory(before, signed, manifest, signing=True)
        (stage / 'signed-inventory.json').write_bytes(canonical(signed))
        filename = f'Jort-{manifest["version"]}-{manifest["build"]}-macos.dmg'
        image = stage / filename
        step('image')
        build_image(app, manifest, image, runner, stage)
        compare_inventory(signed, validate_bundle(app, manifest), manifest)
        step('image-sign')
        runner(['codesign', '--sign', args.identity, '--timestamp', str(image)])
        runner(['codesign', '--verify', '--strict', '--verbose=4', str(image)])
        submitted = artifact_facts(image)
        step('notary')
        notary = json.loads(runner(['xcrun', 'notarytool', 'submit', str(image), '--keychain-profile', args.notary_profile, '--wait', '--timeout', '30m', '--output-format', 'json'], timeout=1900))
        submission = notary.get('id', '')
        require(re.fullmatch(r'[0-9a-fA-F-]{36}', submission) is not None, 'missing notarization submission ID')
        # Store only allowlisted service fields, including on rejection.
        status = notary.get('status') if notary.get('status') in {'Accepted', 'Rejected', 'Invalid', 'In Progress'} else 'Unavailable'
        (stage / 'notary-status.json').write_bytes(canonical({'id': submission, 'status': status}))
        if status != 'Accepted':
            (stage / 'notary-diagnostics.json').write_bytes(canonical(
                notary_diagnostics(submission, status, args.notary_profile, runner)))
        require(status == 'Accepted', 'notarization was not accepted')
        require(artifact_facts(image) == submitted, 'submitted image changed')
        step('staple')
        runner(['xcrun', 'stapler', 'staple', str(image)])
        runner(['xcrun', 'stapler', 'validate', str(image)])
        runner(['codesign', '--verify', '--strict', '--verbose=4', str(image)])
        stapled = artifact_facts(image)
        step('mount')
        mount = stage / 'mount'; mount.mkdir()
        attached = False
        try:
            attachment = plistlib.loads(runner(['hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), '-plist', str(image)]))
            attached = True
            require(any(entity.get('mount-point') == str(mount) for entity in attachment.get('system-entities', [])), 'unexpected mounted volume')
            require({path.name for path in mount.iterdir()} <= {'Jort.app', 'Applications', '.fseventsd', '.Trashes', '.DS_Store', '.VolumeIcon.icns'}, 'unexpected disk image content')
            require((mount / 'Applications').is_symlink() and os.readlink(mount / 'Applications') == '/Applications', 'invalid Applications link')
            compare_inventory(signed, validate_bundle(mount / 'Jort.app', manifest), manifest)
            verify_all(mount / 'Jort.app', manifest, args.team_id, args.identity, runner, stage)
            step('assessment')
            runner(['spctl', '--assess', '--type', 'execute', '--verbose=4', str(mount / 'Jort.app')])
            runner(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', str(image)])
        finally:
            if attached:
                runner(['hdiutil', 'detach', str(mount)])
        runner(['xcrun', 'stapler', 'validate', str(image)])
        require(artifact_facts(image) == stapled and digest(manifest_path) == manifest_hash, 'final artifact/manifest changed')
        record = stage / (filename + '.verification.json')
        record.write_bytes(canonical({'schemaVersion': 1, 'artifact': stapled, 'submittedArtifact': submitted,
                                     'version': manifest['version'], 'build': manifest['build'],
                                     'architectures': sorted(set(args.architectures)), 'sourceRevision': args.revision,
                                     'manifestSHA256': manifest_hash, 'projectSHA256': manifest['projectSHA256'],
                                     'policySHA256': manifest['policySHA256'], 'toolchain': toolchain,
                                     'teamID': args.team_id, 'signatures': signature_evidence,
                                     'notarization': {'id': submission, 'status': 'Accepted'},
                                     'stapleValidated': True, 'gatekeeperApp': True, 'gatekeeperImage': True,
                                     'communityImportEnabled': False}))
        step('publish')
        if args.candidate:
            print(f'Verified qualification candidate retained at dist/{stage.name}; publication remains disabled.')
        else:
            destination = ROOT / 'dist' / f'Jort-{manifest["version"]}-{manifest["build"]}-macos'
            publish(stage, image, record, destination)
            print('Published verified release: dist/' + destination.name)
        return stage
    except Exception:
        # No raw external output or environment is retained.
        (stage / 'failure.json').write_bytes(canonical({'schemaVersion': 1, 'stage': current, 'status': 'failed', 'published': False}))
        print(f'Release failed at {current}; unpublished stage retained: dist/{stage.name}', file=sys.stderr)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--identity', required=True, help='exact Developer ID Application certificate SHA-1')
    parser.add_argument('--team-id', required=True)
    parser.add_argument('--notary-profile', required=True)
    parser.add_argument('--provisioning-profile', required=True, type=Path,
                        help='non-secret Developer ID provisioning profile path')
    parser.add_argument('--architectures', nargs='+', default=['arm64'])
    parser.add_argument('--candidate', action='store_true', help='qualify a signed candidate without publishing')
    parser.add_argument('--fail-at', choices=BOUNDARIES, help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        release(args)
    except (ValueError, OSError, KeyError, json.JSONDecodeError) as error:
        print('Release stopped: ' + ((_notary_text(str(error)) or 'validation failed') if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
