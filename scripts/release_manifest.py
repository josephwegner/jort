#!/usr/bin/env python3
"""Generate a deterministic release contract from declared and resolved inputs.

No inventory from the built application defines expected files. Built Info.plists
are checked against resolved settings; resource expectations come from sources.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shlex
import subprocess
from datetime import datetime

ROOT = Path(__file__).resolve().parent.parent
TYPES = {'application': 'app', 'framework': 'framework', 'xpc-service': 'broker', 'tool': 'worker'}
PRODUCT_TYPES = {'application': 'com.apple.product-type.application', 'framework': 'com.apple.product-type.framework', 'xpc-service': 'com.apple.product-type.xpc-service', 'tool': 'com.apple.product-type.tool'}
SOURCE_EXTENSIONS = {'.swift', '.c', '.h', '.m', '.mm', '.cpp', '.hpp', '.metal'}
PEER_EDGES = {
    'JortJavaScriptClient': [('app-to-broker', 'JortJavaScriptBroker', 'dev.jort.editor.javascript-broker')],
    'JortJavaScriptBroker': [('broker-to-app', 'Jort', 'dev.jort.editor'),
                             ('broker-to-worker', 'JortJavaScriptWorker', 'dev.jort.editor.javascript-worker')],
}
ENTITLEMENT_INPUTS = {'broker': 'Configuration/JortJavaScriptBroker.entitlements',
                      'worker': 'Configuration/JortJavaScriptWorker.entitlements'}


def expected_entitlements(role, team=None, environment='production'):
    # This executable allowlist is deliberately independent of editable JSON.
    # A capability change requires reviewing the enforcement code as well.
    if role == 'app':
        suffix = '.credentials' if environment == 'production' else '.development.credentials'
        return {'keychain-access-groups': [(team or '{TEAM_ID}') + '.dev.jort.editor' + suffix]}
    if role == 'broker':
        return {'com.apple.security.app-sandbox': True}
    if role == 'worker':
        return {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
    require(role == 'framework', 'unknown entitlement role')
    return {}


def entitlement_source(role, production, profile):
    if role != 'app':
        return ENTITLEMENT_INPUTS.get(role)
    return ('Configuration/JortProduction.entitlements' if production else
            'Configuration/JortDevelopment.entitlements' if profile else 'Configuration/JortLocal.entitlements')


def validate_entitlement_sources(root, policy):
    for role in policy['roles'].values():
        require(canonical(role['entitlements']) == canonical(expected_entitlements(role['role'])), 'release entitlement policy widened')
    for role, path in {**ENTITLEMENT_INPUTS, 'app': 'Configuration/JortProduction.entitlements'}.items():
        actual = plistlib.loads((root / path).read_bytes())
        expected = expected_entitlements(role, '$(AppIdentifierPrefix)')
        if role == 'app':
            expected['keychain-access-groups'] = ['$(AppIdentifierPrefix)dev.jort.editor.credentials']
        require(canonical(actual) == canonical(expected), 'release entitlement source drift')


def validate_schema(value, schema=None, document=None):
    """Enforce the checked-in schema's small, explicit keyword vocabulary.

    Fail on unknown validation keywords rather than silently ignoring future
    schema additions. No network resolution or third-party validator is needed.
    """
    if schema is None:
        schema = json.loads((ROOT / 'Configuration/release-manifest.schema.json').read_text())
        document = schema
    supported = {'$schema', '$id', 'title', '$defs', '$ref', 'type', 'required', 'properties',
                 'additionalProperties', 'const', 'enum', 'pattern', 'format', 'oneOf',
                 'items', 'minItems', 'uniqueItems'}
    require(set(schema) <= supported, 'unsupported manifest schema keyword')
    if '$ref' in schema:
        reference = schema['$ref']
        require(reference.startswith('#/$defs/'), 'external manifest schema reference forbidden')
        return validate_schema(value, document['$defs'][reference[len('#/$defs/'):]], document)
    if 'oneOf' in schema:
        matches = 0
        for choice in schema['oneOf']:
            try:
                validate_schema(value, choice, document)
                matches += 1
            except ValueError:
                pass
        require(matches == 1, 'manifest schema alternative mismatch')
    if 'type' in schema:
        kinds = schema['type'] if isinstance(schema['type'], list) else [schema['type']]
        types = {'object': dict, 'array': list, 'string': str, 'boolean': bool, 'null': type(None)}
        require(any(type(value) is types[kind] for kind in kinds), 'manifest schema type mismatch')
    if 'const' in schema:
        require(type(value) is type(schema['const']) and value == schema['const'], 'manifest schema constant mismatch')
    if 'enum' in schema:
        require(any(type(value) is type(option) and value == option for option in schema['enum']), 'manifest schema enum mismatch')
    if isinstance(value, dict):
        require(set(schema.get('required', [])) <= set(value), 'manifest schema required field missing')
        properties = schema.get('properties', {})
        extra = schema.get('additionalProperties', True)
        for key, child in value.items():
            require(key in properties or extra is not False, 'manifest schema unknown field')
            child_schema = properties.get(key, extra)
            if isinstance(child_schema, dict):
                validate_schema(child, child_schema, document)
    if isinstance(value, list):
        require(len(value) >= schema.get('minItems', 0), 'manifest schema array too short')
        if schema.get('uniqueItems'):
            require(len({json.dumps(child, sort_keys=True) for child in value}) == len(value), 'manifest schema duplicate item')
        for child in value:
            if 'items' in schema:
                validate_schema(child, schema['items'], document)
    if isinstance(value, str):
        if 'pattern' in schema:
            require(re.search(schema['pattern'], value) is not None, 'manifest schema pattern mismatch')
        if 'format' in schema:
            require(schema['format'] == 'date-time', 'unsupported manifest schema format')
            try:
                require(datetime.fromisoformat(value.replace('Z', '+00:00')).tzinfo is not None, 'manifest timestamp lacks timezone')
            except ValueError:
                raise ValueError('manifest schema timestamp mismatch') from None


def expected_peer_requirements(target):
    return [{'edge': edge, 'peerTarget': peer, 'teamRelation': 'self',
             'requirementTemplate': f'anchor apple generic and identifier "{identifier}" and certificate leaf[subject.OU] = "%@"'}
            for edge, peer, identifier in PEER_EDGES.get(target, [])]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def safe_path(value, allow_root=False):
    require(isinstance(value, str) and bool(value), 'empty path')
    path = PurePosixPath(value)
    require(not path.is_absolute() and '..' not in path.parts and '\\' not in value and '\x00' not in value,
            'unsafe manifest path')
    require(value == path.as_posix() and (value != '.' or allow_root), 'noncanonical manifest path')
    return path


def command(args, cwd=ROOT):
    result = subprocess.run(args, cwd=cwd, capture_output=True, check=False)
    require(result.returncode == 0, f'{Path(args[0]).name} failed')
    return result.stdout


def read_project(root=ROOT):
    # Ruby/Psych ships with macOS; avoid an undeclared Python package dependency.
    return json.loads(command(['/usr/bin/ruby', '-ryaml', '-rjson', '-e',
                              'puts JSON.generate(YAML.load_file(ARGV[0]))', str(root / 'project.yml')], root))


def read_pbx(root=ROOT):
    return json.loads(command(['plutil', '-convert', 'json', '-o', '-', str(root / 'Jort.xcodeproj/project.pbxproj')], root))


def resolved_versions(settings, targets):
    versions = set()
    seen = set()
    for item in settings:
        if item['target'] not in targets:
            continue
        values = item['buildSettings']
        version, build = str(values.get('MARKETING_VERSION', '')), str(values.get('CURRENT_PROJECT_VERSION', ''))
        require(re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', version) is not None
                and re.fullmatch(r'[0-9]+', build) is not None, 'invalid release version/build')
        versions.add((version, build))
        seen.add(item['target'])
    require(seen == set(targets) and len(versions) == 1, 'incoherent or missing product versions')
    return next(iter(versions))


def shipping_graph(project, policy):
    targets, result = project['targets'], {}

    def visit(name, path, parent):
        require(name in targets, 'unresolved shipping target: ' + name)
        require(name not in result, 'duplicate shipping target: ' + name)
        target = targets[name]
        require(target['type'] in TYPES, 'unsupported shipping product type')
        result[name] = {'path': path, 'parent': parent}
        for dependency in sorted(target.get('dependencies', []), key=lambda item: item.get('target', item.get('sdk', ''))):
            if not dependency.get('embed'):
                continue
            require('target' in dependency, 'unsupported embedded dependency')
            child = dependency['target']
            require(child in targets, 'unresolved embedded target')
            kind = targets[child]['type']
            copy = dependency.get('copy')
            prefix = '' if path == '.' else path + '/'
            if copy:
                require(copy.get('destination') == 'wrapper' and set(copy) == {'destination', 'subpath'}, 'unsupported copy declaration')
                safe_path(copy['subpath'])
                destination = prefix + copy['subpath'] + '/' + child
            elif kind == 'framework':
                destination = prefix + 'Contents/Frameworks/' + child + '.framework'
            elif kind == 'xpc-service':
                destination = prefix + 'Contents/XPCServices/' + child + '.xpc'
            else:
                raise ValueError('unsupported embedded product destination')
            visit(child, destination, name)

    visit(policy['appTarget'], '.', None)
    require(set(result) == set(policy['roles']), 'shipping graph and release role policy differ')
    require(sum(bool(role.get('quickjs')) for role in policy['roles'].values()) == 1, 'exactly one QuickJS role required')
    for name in result:
        require(TYPES[targets[name]['type']] == policy['roles'][name]['role'], 'target role mismatch: ' + name)
        require(not policy['roles'][name].get('quickjs') or policy['roles'][name]['role'] == 'worker', 'QuickJS requires worker role')
    return result


def check_generated_graph(project, pbx, graph):
    objects = pbx['objects']
    native = {value['name']: value for value in objects.values() if value.get('isa') == 'PBXNativeTarget'}
    product_names = {value['productReference']: name for name, value in native.items()}
    for name, location in graph.items():
        require(name in native, 'generated target missing: ' + name)
        target = native[name]
        require(target['productType'] == PRODUCT_TYPES[project['targets'][name]['type']], 'generated product type drift')
        dependencies = {objects[objects[ref]['target']]['name'] for ref in target.get('dependencies', []) if 'target' in objects[ref]}
        expected = {dep['target'] for dep in project['targets'][name].get('dependencies', []) if 'target' in dep}
        require(expected == dependencies, 'generated dependency drift: ' + name)
        copies = {}
        for phase_ref in target['buildPhases']:
            phase = objects[phase_ref]
            if phase['isa'] != 'PBXCopyFilesBuildPhase':
                continue
            for ref in phase.get('files', []):
                product = objects[ref].get('fileRef')
                require(product in product_names, 'unknown generated embedded product')
                child = product_names[product]
                require(child not in copies, 'duplicate generated copy')
                spec = str(phase['dstSubfolderSpec'])
                if spec == '10':
                    folder = 'Contents/Frameworks'
                elif spec in {'1', '16'}:
                    folder = phase.get('dstPath', '')
                    folder = folder.replace('$(CONTENTS_FOLDER_PATH)', 'Contents')
                else:
                    raise ValueError('unsupported generated copy destination')
                prefix = '' if location['path'] == '.' else location['path'] + '/'
                copies[child] = prefix + folder + '/' + objects[product]['path']
        expected_copies = {child: value['path'] for child, value in graph.items() if value['parent'] == name}
        require(copies == expected_copies, 'generated containment drift: ' + name)


def declared_resources(root, target):
    resources = {}
    declarations = target.get('sources', []) + target.get('resources', [])
    for declaration in declarations:
        item = {'path': declaration} if isinstance(declaration, str) else declaration
        require(set(item) <= {'path', 'type', 'buildPhase', 'headerVisibility', 'excludes', 'includes', 'compilerFlags', 'optional'}, 'unsupported source declaration')
        base = root / str(safe_path(item['path']))
        require(base.exists() and not base.is_symlink(), 'missing/linked declared source: ' + item['path'])
        files = sorted(base.rglob('*')) if base.is_dir() else [base]
        for path in files:
            require(not path.is_symlink(), 'linked source resource')
            if not path.is_file():
                continue
            # Finder metadata is ignored by Xcode and never belongs to the
            # declared shipping resource inventory.
            if path.name == '.DS_Store':
                continue
            relative = path.relative_to(base).as_posix() if base.is_dir() else path.name
            excludes = item.get('excludes', [])
            if any(relative == pattern or relative.startswith(pattern + '/') or fnmatch.fnmatch(relative, pattern) for pattern in excludes):
                continue
            if 'includes' in item and not any(fnmatch.fnmatch(relative, pattern) for pattern in item['includes']):
                continue
            if item.get('buildPhase') in {'headers', 'sources', 'none'} or path.suffix in SOURCE_EXTENSIONS:
                continue
            if path.suffix in {'.patch', '.md'}:
                continue  # XcodeGen does not put engineering notes in Resources.
            require(path.suffix not in {'.xcassets', '.storyboard', '.xib'} and not any(p.endswith('.xcassets') for p in path.parts), 'unsupported compiled resource')
            if item.get('type') == 'folder':
                destination = base.name + '/' + relative
            else:
                localized = next((i for i, part in enumerate(path.parts) if part.endswith('.lproj')), None)
                destination = '/'.join(path.parts[localized:]) if localized is not None else path.name
            require(destination not in resources, 'resource destination collision: ' + destination)
            # Xcode canonicalizes .strings to binary plist; compare parsed values.
            value = {'source': path.relative_to(root).as_posix(), 'mode': 420}
            if path.suffix == '.strings':
                value['plist'] = plistlib.loads(command(['plutil', '-convert', 'binary1', '-o', '-', str(path)], root))
            else:
                value['sha256'] = digest(path)
            resources[destination] = value
    return resources


def target_uses_swift(root, target):
    for declaration in target.get('sources', []):
        item = {'path': declaration} if isinstance(declaration, str) else declaration
        path = root / item['path']
        if path.is_file() and path.suffix == '.swift':
            return True
        if path.is_dir() and any(candidate.is_file() for candidate in path.rglob('*.swift')):
            return True
    return False


def generate(root, settings, app, production=False, team_id=None, metadata=None,
             provisioning_profile=None, profile_environment=None, signing_identity=None):
    root, app = Path(root), Path(app)
    policy = json.loads((root / 'Configuration/release-policy.json').read_text())
    require(policy['schemaVersion'] == 1, 'unsupported role policy')
    validate_entitlement_sources(root, policy)
    require(policy.get('peerRequirements') == {target: expected_peer_requirements(target) for target in PEER_EDGES},
            'runtime peer policy drift')
    project, pbx = read_project(root), read_pbx(root)
    graph = shipping_graph(project, policy)
    check_generated_graph(project, pbx, graph)
    resolved_versions(settings, graph)
    resolved = {}
    for item in settings:
        if item['target'] in resolved:
            require(
                resolved[item['target']] == item['buildSettings'],
                'conflicting duplicate resolved target: ' + item['target'])
        else:
            resolved[item['target']] = item['buildSettings']
    require(set(graph) <= set(resolved), 'missing resolved target settings')
    profile_team = team_id
    if production:
        require(bool(re.fullmatch(r'[A-Z0-9]{10}', team_id or '')), 'invalid production Team ID')
    elif provisioning_profile is None:
        team_id = None
    profile_facts = None
    if provisioning_profile is not None:
        # Import lazily so the ordinary credential-free manifest path has no
        # dependency on Security.framework tooling.
        from provisioning_profile import inspect as inspect_profile
        require(profile_team is not None and profile_environment in {'development', 'production'},
                'signed profile requires Team ID and environment')
        require((profile_environment == 'production') == production,
                'profile environment does not match manifest mode')
        profile_facts = inspect_profile(provisioning_profile, profile_team, profile_environment, signing_identity)
    objects, files, links = [], {}, {}
    versions = None
    for name, location in sorted(graph.items()):
        values, role = resolved[name], policy['roles'][name]
        require(values.get('CONFIGURATION') == 'Release', 'Release settings required')
        identifier = values.get('PRODUCT_BUNDLE_IDENTIFIER')
        require(identifier and '$' not in identifier, 'unresolved bundle identifier')
        require(identifier == role.get('identifier', identifier), 'stable identity drift: ' + name)
        version = [str(values['MARKETING_VERSION']), str(values['CURRENT_PROJECT_VERSION'])]
        require(all(re.fullmatch(r'\d+(?:\.\d+)*', value) for value in version), 'invalid version')
        require(
            versions is None or versions == version,
            f'incoherent product versions for {name}: {version!r} differs from {versions!r}')
        versions = version
        path = location['path']
        prefix = '' if path == '.' else path + '/'
        executable_name = values['EXECUTABLE_NAME']
        require(executable_name == name, 'unsupported product executable rename')
        architectures = sorted(set(shlex.split(values['ARCHS'])))
        require(architectures and set(architectures) <= set(policy['supportedArchitectures']), 'unsupported architecture')
        kind = role['role']
        if kind == 'framework':
            require(values.get('FRAMEWORK_VERSION', 'A') == 'A', 'unsupported framework version')
            executable, plist = prefix + 'Versions/A/' + name, prefix + 'Versions/A/Resources/Info.plist'
            resource_prefix = prefix + 'Versions/A/Resources/'
            links.update({prefix + 'Versions/Current': 'A', prefix + name: 'Versions/Current/' + name, prefix + 'Resources': 'Versions/Current/Resources'})
        elif kind == 'worker':
            executable, plist, resource_prefix = path, None, None
        else:
            executable, plist = prefix + 'Contents/MacOS/' + name, prefix + 'Contents/Info.plist'
            resource_prefix = prefix + 'Contents/Resources/'
        expected_executable = (Path(values['EXECUTABLE_PATH']).as_posix())
        relative_executable = executable if path == '.' else executable.removeprefix(prefix)
        if kind == 'worker':
            relative_executable = name
        else:
            expected_executable = expected_executable.removeprefix(values['FULL_PRODUCT_NAME'] + '/')
        require(expected_executable == relative_executable, 'resolved executable path drift: ' + name)
        files[executable] = {'kind': 'code', 'mode': 493}
        info = {'CFBundleIdentifier': identifier, 'CFBundleExecutable': name, 'CFBundleShortVersionString': version[0], 'CFBundleVersion': version[1]}
        if kind == 'app':
            info['CFBundleIconFile'] = project['targets'][name]['info']['properties']['CFBundleIconFile']
            info['JortCredentialEnvironment'] = 'production' if production else 'development'
            info['JortExpectedTeamIdentifier'] = team_id or ''
            files[prefix + 'Contents/PkgInfo'] = {'kind': 'resource', 'mode': 420, 'sha256': hashlib.sha256(b'APPL????').hexdigest()}
            if profile_facts is not None:
                files[prefix + 'Contents/embedded.provisionprofile'] = {
                    'kind': 'resource', 'mode': 420, 'sha256': profile_facts['sha256']}
        if plist:
            require(all(plistlib.loads((app / plist).read_bytes()).get(key) == value for key, value in info.items()), 'built plist differs from resolved identity: ' + name)
            files[plist] = {'kind': 'plist', 'mode': 420, 'values': info}
        resources = declared_resources(root, project['targets'][name])
        require(not resources or resource_prefix is not None, 'resources on unbundled tool')
        for destination, expectation in resources.items():
            full = resource_prefix + destination
            require(full not in files, 'resource/code collision')
            files[full] = dict(expectation, kind='resource')
        entitlements = json.loads(json.dumps(role['entitlements']).replace('{TEAM_ID}', team_id or '{TEAM_ID}'))
        if profile_facts is not None and not production and kind == 'app':
            entitlements = {'keychain-access-groups': [profile_facts['keychainAccessGroup']]}
        if production:
            require(values.get('ENABLE_HARDENED_RUNTIME') == 'YES', 'Hardened Runtime disabled')
        runpaths = set(shlex.split(values.get('LD_RUNPATH_SEARCH_PATHS', '')))
        if target_uses_swift(root, project['targets'][name]):
            runpaths.update(policy.get('swiftSystemRunpaths', []))
        expected_input = entitlement_source(kind, production, profile_facts)
        require((values.get('CODE_SIGN_ENTITLEMENTS') or None) == expected_input,
                'resolved entitlement source mismatch')
        objects.append(dict(location, target=name, role=kind, identifier=identifier,
                            executable=executable, executableMode=493, architectures=architectures,
                            infoPlist=plist, infoValues=info, teamID=team_id, hardenedRuntime=True,
                            entitlements=entitlements, quickjs=bool(role.get('quickjs')),
                            peerRequirements=policy['peerRequirements'].get(name, []),
                            dependencies=sorted(dep['target'] for dep in project['targets'][name].get('dependencies', []) if 'target' in dep and dep.get('link', True)),
                            runpaths=sorted(runpaths),
                            entitlementInput=expected_input,
                            entitlementSHA256=digest(root / expected_input) if expected_input else None))
    require(set(policy['requiredResources']) <= set(files), 'required public resource missing')
    if metadata is None:
        metadata = {'sourceRevision': command(['git', 'rev-parse', 'HEAD'], root).decode().strip(),
                    'toolchain': command(['xcodebuild', '-version'], root).decode().strip(),
                    'xcodegen': command(['xcodegen', '--version'], root).decode().strip()}
    manifest = dict(schemaVersion=1, configuration='Release', production=production,
                    version=versions[0], build=versions[1], objects=objects, files=files, symlinks=links,
                    directories=sorted(policy.get('requiredDirectories', [])),
                    systemDependencyRoots=policy['systemDependencyRoots'], forbiddenPaths=policy['forbiddenPaths'],
                    projectSHA256=digest(root / 'project.yml'), generatedProjectSHA256=digest(root / 'Jort.xcodeproj/project.pbxproj'),
                    policySHA256=digest(root / 'Configuration/release-policy.json'),
                    provisioningProfile=profile_facts, **metadata)
    validate_manifest(manifest)
    return manifest


def validate_manifest(manifest):
    from release_inputs import scan_manifest
    scan_manifest(manifest)
    validate_schema(manifest)
    require(manifest.get('schemaVersion') == 1, 'unsupported manifest schema')
    require(manifest.get('configuration') == 'Release', 'invalid manifest configuration')
    profile = manifest.get('provisioningProfile')
    if profile is not None:
        require(set(profile) == {'sha256', 'teamID', 'environment', 'platform', 'signingCertificateSHA1',
                                 'applicationIdentifier', 'keychainAccessGroup', 'expiration', 'uuid', 'name'},
                'invalid provisioning profile facts')
        require(re.fullmatch(r'[0-9a-f]{64}', profile['sha256']) is not None, 'invalid profile hash')
        require(profile['environment'] in {'development', 'production'}, 'invalid profile environment')
        require((profile['environment'] == 'production') == manifest['production'],
                'profile environment/manifest mismatch')
        require(profile['platform'] == 'OSX', 'invalid profile platform')
        require(re.fullmatch(r'[0-9A-F]{40}', profile['signingCertificateSHA1']) is not None,
                'invalid profile signing certificate')
        require(re.fullmatch(r'[A-Z0-9]{10}', profile['teamID']) is not None, 'invalid profile Team ID')
        require(profile['applicationIdentifier'] == profile['teamID'] + '.dev.jort.editor',
                'invalid profile application identifier')
        suffix = '.credentials' if profile['environment'] == 'production' else '.development.credentials'
        require(profile['keychainAccessGroup'] == profile['teamID'] + '.dev.jort.editor' + suffix,
                'invalid profile credential group')
        require('Contents/embedded.provisionprofile' in manifest['files'], 'profile missing from inventory')
        require(manifest['files']['Contents/embedded.provisionprofile'] ==
                {'kind': 'resource', 'mode': 420, 'sha256': profile['sha256']},
                'embedded profile inventory mismatch')
    objects = manifest['objects']
    require(bool(objects), 'empty shipping inventory')
    for field in ('target', 'path', 'identifier', 'executable'):
        require(len({item[field] for item in objects}) == len(objects), 'duplicate manifest ' + field)
    by_target = {item['target']: item for item in objects}
    apps = [item for item in objects if item['role'] == 'app']
    require(len(apps) == 1 and apps[0]['path'] == '.' and apps[0]['parent'] is None, 'invalid manifest root')
    require(sum(item['quickjs'] for item in objects) == 1, 'invalid engine ownership')
    for item in objects:
        environment = profile['environment'] if profile else 'production'
        require(canonical(item['entitlements']) == canonical(expected_entitlements(item['role'], item['teamID'], environment)),
                'manifest entitlement capability drift')
        source = entitlement_source(item['role'], manifest['production'], profile)
        require(item['entitlementInput'] == source, 'manifest entitlement source drift')
        require(item['entitlementSHA256'] == (digest(ROOT / source) if source else None),
                'manifest entitlement source hash mismatch')
        if source:
            source_values = plistlib.loads((ROOT / source).read_bytes())
            if item['role'] == 'app' and not manifest['production'] and profile is None:
                source_expected = {'com.apple.security.get-task-allow': True,
                                   'com.apple.security.cs.disable-library-validation': True}
            else:
                source_expected = expected_entitlements(item['role'], item['teamID'], environment)
                if item['role'] == 'app':
                    suffix = '.credentials' if environment == 'production' else '.development.credentials'
                    source_expected['keychain-access-groups'] = ['$(AppIdentifierPrefix)dev.jort.editor' + suffix]
            require(canonical(source_values) == canonical(source_expected), 'manifest entitlement source capabilities drift')
        require(item.get('peerRequirements') == expected_peer_requirements(item['target']),
                'invalid runtime peer requirements: ' + item['target'])
        for peer in item['peerRequirements']:
            require(peer['peerTarget'] in by_target, 'missing runtime peer target')
            expected_identifier = next(identifier for edge, target, identifier in PEER_EDGES[item['target']]
                                       if edge == peer['edge'])
            require(by_target[peer['peerTarget']]['identifier'] == expected_identifier,
                    'runtime peer identifier drift')
        safe_path(item['path'], True)
        safe_path(item['executable'])
        require(item['executable'] in manifest['files'] and manifest['files'][item['executable']]['kind'] == 'code', 'missing code inventory')
        require(item['architectures'] and set(item['architectures']) <= {'arm64', 'x86_64'}, 'invalid architectures')
        require(not item['quickjs'] or item['role'] == 'worker', 'engine outside worker')
        require(set(item['dependencies']) <= set(by_target), 'unresolved manifest dependency')
        if profile is not None:
            require(item['teamID'] == profile['teamID'], 'signed profile/object Team mismatch')
            groups = item['entitlements'].get('keychain-access-groups', [])
            if item['role'] == 'app':
                require(groups == [profile['keychainAccessGroup']], 'app/profile credential group mismatch')
            else:
                require(not groups, 'helper credential group forbidden')
        if item['parent'] is not None:
            require(item['parent'] in by_target, 'unknown containing object')
            parent_path = by_target[item['parent']]['path']
            require(parent_path == '.' or item['path'].startswith(parent_path + '/'), 'inconsistent containment')
            candidates = [candidate for candidate in objects if candidate['path'] != item['path'] and (candidate['path'] == '.' or item['path'].startswith(candidate['path'] + '/'))]
            require(max(candidates, key=lambda candidate: len(candidate['path']))['target'] == item['parent'], 'incorrect immediate parent')
    for path in list(manifest['files']) + list(manifest['symlinks']) + manifest['directories'] + manifest['forbiddenPaths']:
        safe_path(path)
    require(not (set(manifest['files']) & set(manifest['symlinks'])), 'duplicate file/link path')
    require(not (set(manifest['directories']) & (set(manifest['files']) | set(manifest['symlinks']))), 'directory collides with file/link')
    require(len(manifest['directories']) == len(set(manifest['directories'])), 'duplicate manifest directory')
    for forbidden in manifest['forbiddenPaths']:
        require(not any(path == forbidden or path.startswith(forbidden + '/') for path in manifest['files']), 'forbidden manifest path')
    for path, target in manifest['symlinks'].items():
        require(not PurePosixPath(target).is_absolute(), 'absolute link target')
        normalized = os.path.normpath(str(PurePosixPath(path).parent / target))
        safe_path(normalized)
    require(manifest['systemDependencyRoots'] == ['/System/Library/', '/usr/lib/'], 'unsupported system dependency allowlist')
    return manifest


def load(path):
    return validate_manifest(json.loads(Path(path).read_text()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['generate', 'validate'])
    parser.add_argument('--settings', type=Path)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--production', action='store_true')
    parser.add_argument('--team-id')
    parser.add_argument('--provisioning-profile', type=Path)
    parser.add_argument('--profile-environment', choices=('development', 'production'))
    parser.add_argument('--signing-identity')
    args = parser.parse_args()
    if args.command == 'validate':
        load(args.output)
    else:
        require(args.settings and args.app, '--settings and --app are required')
        manifest = generate(ROOT, json.loads(args.settings.read_text()), args.app, args.production, args.team_id,
                            provisioning_profile=args.provisioning_profile,
                            profile_environment=args.profile_environment,
                            signing_identity=args.signing_identity)
        with args.output.open('xb') as stream:
            stream.write(canonical(manifest))
        args.output.chmod(0o444)
    print('Release manifest validated.')


if __name__ == '__main__':
    main()
