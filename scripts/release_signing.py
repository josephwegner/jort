#!/usr/bin/env python3
"""Explicit inside-out signing and exact, immediate identity verification."""
import hashlib
from pathlib import Path
import plistlib
import re
import struct
import tempfile

from release_manifest import canonical, digest, expected_entitlements, require, validate_manifest
from release_validation import macho_slices


def verify_peer_requirements(path, item):
    """Read runtime-consumed templates from every sealed Mach-O slice."""
    expected = sorted('JORT_PEER_V1|' + peer['edge'] + '|' + peer['requirementTemplate']
                      for peer in item['peerRequirements'])
    slices = macho_slices(Path(path).read_bytes())
    require(len(slices) == len(item['architectures']), 'peer-policy architecture count mismatch')
    for data in slices:
        require(data[:4] == b'\xcf\xfa\xed\xfe' and len(data) >= 32, 'unsupported peer-policy Mach-O slice')
        count, size = struct.unpack_from('<II', data, 16)
        require(32 + size <= len(data), 'truncated peer-policy commands')
        offset, markers, found = 32, [], False
        for _ in range(count):
            require(offset + 8 <= 32 + size, 'truncated peer-policy load command')
            kind, length = struct.unpack_from('<II', data, offset)
            require(length >= 8 and offset + length <= 32 + size, 'malformed peer-policy load command')
            if kind == 0x19:
                require(length >= 72, 'truncated peer-policy segment')
                segment = data[offset + 8:offset + 24].rstrip(b'\0')
                section_count = struct.unpack_from('<I', data, offset + 64)[0]
                require(72 + section_count * 80 <= length, 'truncated peer-policy sections')
                for index in range(section_count):
                    section = offset + 72 + index * 80
                    if data[section:section + 16].rstrip(b'\0') != b'__jort_peer':
                        continue
                    require(segment == b'__TEXT' and not found, 'unexpected/duplicate peer-policy section')
                    require(data[section + 16:section + 32].rstrip(b'\0') == b'__TEXT', 'invalid peer-policy segment')
                    found = True
                    section_size = struct.unpack_from('<Q', data, section + 40)[0]
                    section_offset = struct.unpack_from('<I', data, section + 48)[0]
                    require(section_size > 0 and section_offset >= 32 + size
                            and section_offset + section_size <= len(data), 'truncated peer-policy payload')
                    payload = data[section_offset:section_offset + section_size]
                    require(payload.endswith(b'\0'), 'unterminated peer-policy marker')
                    try:
                        markers = [value.decode('ascii') for value in payload.split(b'\0') if value]
                    except UnicodeDecodeError as error:
                        raise ValueError('non-ASCII peer-policy marker') from error
            offset += length
        require(offset == 32 + size, 'peer-policy command size mismatch')
        require(sorted(markers) == expected, 'compiled runtime peer policy mismatch: ' + item['target'])
    return True


def signing_plan(manifest):
    validate_manifest(manifest)
    by_name = {item['target']: item for item in manifest['objects']}
    def depth(item):
        seen = set()
        while item['parent'] is not None:
            require(item['target'] not in seen, 'containment cycle')
            seen.add(item['target'])
            item = by_name[item['parent']]
        return len(seen)
    return sorted(manifest['objects'], key=lambda item: (-depth(item), item['path']))


def designated_requirement(item, team):
    require(re.fullmatch(r'[A-Za-z0-9.-]+', item['identifier']) is not None, 'unsafe code identifier')
    require(re.fullmatch(r'[A-Z0-9]{10}', team) is not None, 'unsafe Team ID')
    return f'identifier "{item["identifier"]}" and anchor apple generic and certificate leaf[subject.OU] = "{team}" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'


def validate_signature_facts(item, facts, team, identity):
    require(canonical(item['entitlements']) == canonical(expected_entitlements(item['role'], team)), 'distribution entitlement capability drift')
    require(facts['identifier'] == item['identifier'], 'signature identifier mismatch')
    require(facts['teamID'] == team and item['teamID'] == team, 'signature Team mismatch')
    require(facts['runtime'] is True and facts['timestamp'] is True, 'missing runtime/timestamp')
    require(facts['developerID'] is True and facts['validCertificate'] is True, 'invalid distribution certificate')
    require(facts['certificateSHA1'] == identity.upper(), 'signer certificate mismatch')
    require(canonical(facts['entitlements']) == canonical(item['entitlements']), 'unexpected effective entitlements')
    require(facts['requirementSatisfied'] is True and facts['strictVerification'] is True, 'invalid designated requirement/resource seal')


def verify_object(app, item, team, identity, runner, scratch):
    path = Path(app) / item['path']
    verify_peer_requirements(Path(app) / item['executable'], item)
    runner(['codesign', '--verify', '--strict', '--verbose=4',
            '-R=' + designated_requirement(item, team), str(path)])
    details = runner(['codesign', '--display', '--verbose=4', str(path)], combined=True).decode()
    requirement = runner(['codesign', '--display', '-r-', str(path)], combined=True).decode()
    require(f'identifier "{item["identifier"]}"' in requirement and 'anchor apple' in requirement and team in requirement, 'unexpected designated requirement')
    entitlement_data = runner(['codesign', '--display', '--entitlements', ':-', str(path)])
    # Empty entitlement output is the only accepted representation for frameworks.
    entitlements = plistlib.loads(entitlement_data) if entitlement_data.strip() else {}
    prefix = str(Path(scratch) / (item['target'] + '-certificate-'))
    runner(['codesign', '--display', '--extract-certificates=' + prefix, str(path)])
    certificate = Path(prefix + '0')
    require(certificate.is_file(), 'signature certificate missing')
    certificate_metadata = runner(['openssl', 'x509', '-inform', 'DER', '-in', str(certificate), '-noout', '-fingerprint', '-sha1', '-enddate', '-subject', '-nameopt', 'RFC2253']).decode()
    runner(['openssl', 'x509', '-inform', 'DER', '-in', str(certificate), '-noout', '-checkend', '0'])
    fingerprint = re.search(r'(?:SHA1|sha1) Fingerprint=([0-9A-F:]+)', certificate_metadata)
    require(fingerprint is not None and re.search(r'(?:^|,)OU=' + team + r'(?:,|$)', certificate_metadata, re.M), 'certificate Team mismatch')
    def field(name):
        match = re.search(r'^' + name + r'=(.+)$', details, re.M)
        return match.group(1) if match else None
    facts = {'identifier': field('Identifier'), 'teamID': field('TeamIdentifier'),
             'runtime': bool(re.search(r'flags=.*\bruntime\b', details)),
             'timestamp': bool(field('Timestamp')) and field('Timestamp') != 'none',
             'developerID': 'Authority=Developer ID Application:' in details,
             'validCertificate': True, 'certificateSHA1': fingerprint.group(1).replace(':', ''),
             'entitlements': entitlements, 'requirementSatisfied': True, 'strictVerification': True}
    validate_signature_facts(item, facts, team, identity)
    expiry = re.search(r'^notAfter=(.+)$', certificate_metadata, re.M)
    return {'target': item['target'], 'identifier': item['identifier'], 'teamID': team,
            'certificateSHA256': digest(certificate), 'certificateSHA1': facts['certificateSHA1'],
            'certificateExpiry': expiry.group(1) if expiry else None,
            'hardenedRuntime': True, 'secureTimestamp': True, 'entitlementsVerified': True,
            'designatedRequirementVerified': True, 'runtimePeerRequirementsVerified': True}


def verify_all(app, manifest, team, identity, runner, scratch):
    facts = [verify_object(app, item, team, identity, runner, scratch) for item in signing_plan(manifest)]
    runner(['codesign', '--verify', '--deep', '--strict', '--verbose=4', str(app)])
    return facts


def sign_all(app, manifest, team, identity, runner, scratch):
    require(manifest['production'], 'production manifest required for distribution signing')
    evidence, sealed = [], {}
    for item in signing_plan(manifest):
        for path, expected in sealed.items():
            require(digest(path) == expected, 'already signed code was mutated')
        entitlement_path = Path(scratch) / (item['target'] + '.entitlements')
        entitlement_path.write_bytes(plistlib.dumps(item['entitlements']))
        args = ['codesign', '--force', '--sign', identity, '--identifier', item['identifier'], '--timestamp', '--options', 'runtime']
        if item['entitlements']:
            args += ['--generate-entitlement-der', '--entitlements', str(entitlement_path)]
        args.append(str(Path(app) / item['path']))
        runner(args)
        evidence.append(verify_object(app, item, team, identity, runner, scratch))
        sealed[Path(app) / item['executable']] = digest(Path(app) / item['executable'])
    for path, expected in sealed.items():
        require(digest(path) == expected, 'signed child changed during parent signing')
    runner(['codesign', '--verify', '--deep', '--strict', '--verbose=4', str(app)])
    return evidence
