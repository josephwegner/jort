#!/usr/bin/env python3
"""Validate and embed the non-secret provisioning profile selected for Jort.

Profiles are signed CMS documents in normal operation.  The parser deliberately
projects only the facts that are safe to freeze into a release manifest.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess


def require(condition, message):
    if not condition:
        raise ValueError(message)


def _profile_bytes(path, decoder=None):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'provisioning profile must be a regular file')
    if decoder is not None:
        return decoder(path)
    result = subprocess.run(['security', 'cms', '-D', '-i', str(path)], capture_output=True)
    require(result.returncode == 0, 'provisioning profile CMS decode failed')
    return result.stdout


def expected_group(team_id, environment):
    require(environment in {'development', 'production'}, 'invalid credential environment')
    suffix = '.development.credentials' if environment == 'development' else '.credentials'
    return team_id + '.dev.jort.editor' + suffix


def authorizes_credential_group(groups, team_id, environment):
    """Require a Team-scoped profile allowlist to authorize the selected group.

    Apple provisioning profiles may use a Team-scoped trailing wildcard such as
    ``TEAMID.*``.  That is an authorization boundary, not the entitlement the
    application receives: the signed application still claims one exact,
    environment-specific group.  Reject malformed or foreign-Team entries so a
    profile cannot silently widen the Team boundary.
    """
    expected = expected_group(team_id, environment)
    require(isinstance(groups, list) and groups, 'profile credential groups missing')
    authorized = False
    wildcard_pattern = re.compile(re.escape(team_id) + r'(?:\.[A-Za-z0-9][A-Za-z0-9-]*)*\.\*$')
    for entry in groups:
        require(isinstance(entry, str) and entry, 'invalid profile credential group')
        if '*' in entry:
            require(entry.startswith(team_id + '.'), 'profile credential group wildcard has wrong Team')
            require(wildcard_pattern.fullmatch(entry) is not None,
                    'profile credential group wildcard is malformed or too broad')
            authorized = authorized or expected.startswith(entry[:-1])
            continue
        # Profiles can contain unrelated exact entries (for example
        # com.apple.token).  They do not become app entitlements: signature
        # verification separately requires the app's exact selected group.
        authorized = authorized or entry == expected
    require(authorized, 'profile does not authorize the expected credential group')
    return expected


def resolve_apple_development_identity(selector, team_id, runner=None, certificate_team=None):
    """Resolve a protected-lane selector to one exact Apple Development SHA-1.

    The parenthetical value in an Apple Development identity's display name is
    not the Team ID.  It is an Apple-generated certificate identifier, so use
    the leaf certificate's subject OU as the Team authority instead.
    """
    require(isinstance(selector, str) and selector, 'missing Apple Development identity selector')
    output = (runner or _security_identities)(['security', 'find-identity', '-v', '-p', 'codesigning'])
    if isinstance(output, bytes):
        output = output.decode(errors='strict')
    candidates = []
    for fingerprint, name in re.findall(
            r'^\s*\d+\)\s+([0-9A-F]{40})\s+"(Apple Development: [^"]+)"', output, re.M):
        if selector.upper() == fingerprint or selector == name:
            actual_team = (certificate_team or _certificate_subject_team)(fingerprint, name)
            if actual_team == team_id:
                candidates.append(fingerprint)
    require(len(candidates) == 1, 'Apple Development identity absent, ambiguous, or wrong Team')
    return candidates[0]


def _security_identities(args):
    result = subprocess.run(args, capture_output=True)
    require(result.returncode == 0, 'security identity lookup failed')
    return result.stdout + result.stderr


def _certificate_subject_team(fingerprint, name):
    """Read one certificate's Team ID from its public subject metadata."""
    result = subprocess.run(
        ['security', 'find-certificate', '-a', '-Z', '-p', '-c', name], capture_output=True)
    require(result.returncode == 0, 'security certificate lookup failed')
    output = result.stdout.decode(errors='strict')
    pem_matches = re.findall(
        r'SHA-1 hash:\s*([0-9A-F]{40})\s*(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)',
        output, re.S)
    selected = [pem for found, pem in pem_matches if found == fingerprint]
    require(len(selected) == 1, 'Apple Development certificate metadata absent or ambiguous')
    subject = subprocess.run(
        ['openssl', 'x509', '-noout', '-subject', '-nameopt', 'RFC2253'],
        input=selected[0].encode(), capture_output=True)
    require(subject.returncode == 0, 'Apple Development certificate subject lookup failed')
    match = re.search(r'(?:^|,)OU=([A-Z0-9]{10})(?:,|$)', subject.stdout.decode(errors='strict').strip())
    require(match is not None, 'Apple Development certificate Team ID missing')
    return match.group(1)


def _mac_provisioning_udid():
    result = subprocess.run(['/usr/sbin/system_profiler', 'SPHardwareDataType', '-json'], capture_output=True)
    require(result.returncode == 0, 'cannot read current Mac provisioning UDID')
    try:
        value = json.loads(result.stdout)['SPHardwareDataType'][0]['provisioning_UDID']
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as error:
        raise ValueError('current Mac provisioning UDID unavailable') from error
    require(isinstance(value, str) and value, 'current Mac provisioning UDID unavailable')
    return value


def inspect(path, team_id, environment, certificate_sha1, decoder=None, now=None, device_provider=None):
    """Return allowlisted profile facts after exact authorization checks."""
    require(len(team_id) == 10 and team_id.isalnum() and team_id.upper() == team_id, 'invalid Team ID')
    try:
        profile = plistlib.loads(_profile_bytes(path, decoder))
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ValueError('provisioning profile is not a plist') from error
    entitlements = profile.get('Entitlements')
    require(isinstance(entitlements, dict), 'profile entitlements missing')
    teams = profile.get('TeamIdentifier')
    prefixes = profile.get('ApplicationIdentifierPrefix')
    require(teams == [team_id] and prefixes == [team_id], 'profile Team ID mismatch')
    require(profile.get('Platform') == ['OSX'], 'profile is not a macOS profile')
    application_keys = [key for key in ('application-identifier', 'com.apple.application-identifier')
                        if key in entitlements]
    require(len(application_keys) == 1, 'profile application identifier is ambiguous or missing')
    application_identifier = team_id + '.dev.jort.editor'
    require(entitlements[application_keys[0]] == application_identifier,
            'profile application identifier mismatch')
    devices = profile.get('ProvisionedDevices')
    all_devices = profile.get('ProvisionsAllDevices')
    if environment == 'development':
        require(isinstance(devices, list) and all(isinstance(device, str) and device for device in devices)
                and bool(devices) and all_devices is not True,
                'development profile must authorize explicit devices')
        require((device_provider or _mac_provisioning_udid)() in devices,
                'development profile does not authorize this Mac')
    else:
        require(all_devices is True and 'ProvisionedDevices' not in profile,
                'distribution profile must authorize all devices only')
    require(isinstance(certificate_sha1, str) and __import__('re').fullmatch(r'[0-9A-Fa-f]{40}', certificate_sha1),
            'invalid signing certificate SHA-1')
    certificates = profile.get('DeveloperCertificates')
    require(isinstance(certificates, list) and certificates, 'profile signing certificates missing')
    certificate_hashes = [hashlib.sha1(bytes(certificate)).hexdigest().upper()
                          for certificate in certificates if isinstance(certificate, (bytes, bytearray))]
    require(len(certificate_hashes) == len(certificates), 'invalid profile signing certificate')
    selected_certificate = certificate_sha1.upper()
    require(certificate_hashes.count(selected_certificate) == 1,
            'selected signing certificate is absent or ambiguous in profile')
    group = authorizes_credential_group(entitlements.get('keychain-access-groups'), team_id, environment)
    expiration = profile.get('ExpirationDate')
    require(isinstance(expiration, datetime), 'profile expiration missing')
    expiration = expiration if expiration.tzinfo else expiration.replace(tzinfo=timezone.utc)
    now = now or datetime.now(timezone.utc)
    require(expiration > now, 'provisioning profile expired')
    uuid = profile.get('UUID')
    require(isinstance(uuid, str) and uuid, 'profile UUID missing')
    name = profile.get('Name')
    require(isinstance(name, str) and name, 'profile name missing')
    return {
        'sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest(),
        'teamID': team_id,
        'environment': environment,
        'platform': 'OSX',
        'signingCertificateSHA1': selected_certificate,
        'applicationIdentifier': application_identifier,
        'keychainAccessGroup': group,
        'expiration': expiration.astimezone(timezone.utc).isoformat().replace('+00:00', 'Z'),
        'uuid': uuid,
        'name': name,
    }


def embed(profile, app):
    profile, app = Path(profile), Path(app)
    destination = app / 'Contents/embedded.provisionprofile'
    require(app.is_dir() and (app / 'Contents').is_dir(), 'application bundle missing')
    require(not destination.exists() and not destination.is_symlink(), 'embedded provisioning profile already exists')
    # Copy the payload explicitly rather than asking the platform copy routine
    # to copy a file.  In particular, provisioning inputs may have Finder
    # provenance or quarantine xattrs which must not become signed bundle
    # metadata (and can change when a DMG is mounted).
    with profile.open('rb') as source, destination.open('xb') as output:
        while chunk := source.read(1024 * 1024):
            output.write(chunk)
    destination.chmod(0o644)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('validate', 'embed', 'resolve-development-identity'))
    parser.add_argument('--profile', type=Path)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--team-id')
    parser.add_argument('--identity')
    parser.add_argument('--environment', choices=('development', 'production'))
    args = parser.parse_args()
    if args.command == 'resolve-development-identity':
        require(args.team_id is not None and args.identity is not None, 'Team ID and identity are required')
        print(resolve_apple_development_identity(args.identity, args.team_id))
    elif args.command == 'validate':
        require(args.profile is not None and args.team_id is not None and args.environment is not None and args.identity is not None,
                'profile, Team ID, identity, and environment are required')
        facts = inspect(args.profile, args.team_id, args.environment, args.identity)
        print(plistlib.dumps(facts).decode(), end='')
    else:
        require(args.profile is not None and args.app is not None, 'profile and application are required')
        embed(args.profile, args.app)


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        raise SystemExit('Provisioning profile rejected: ' + str(error))
