#!/usr/bin/env python3
"""Strict bundle, Mach-O closure, and frozen-inventory validation."""
from __future__ import annotations

import hashlib
import ctypes
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess

from release_manifest import digest, require, validate_manifest

MACH_MAGICS = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}
ENGINE = re.compile(r'\b_?(?:JS_NewRuntime\w*|JS_NewContext\w*|JS_Eval\w*|js_std_\w*|JortJavaScriptEvaluate\w*|JortJavaScriptValidate\w*)\b|(?:QuickJS|JortJavaScript\.framework)')


def run(args):
    result = subprocess.run(args, capture_output=True)
    require(result.returncode == 0, Path(args[0]).name + ' inspection failed')
    return result.stdout.decode(errors='strict')


def parsed_plist(path):
    result = subprocess.run(
        ['plutil', '-convert', 'binary1', '-o', '-', str(path)], capture_output=True)
    require(result.returncode == 0, 'plist/resource parse failed')
    return plistlib.loads(result.stdout)


def macho_slices(data):
    require(data[:4] in MACH_MAGICS, 'not a supported Mach-O')
    if data[:4] == b'\xcf\xfa\xed\xfe':
        return [data]
    require(data[:4] in {b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}, 'unsupported Mach-O byte order')
    count = struct.unpack_from('>I', data, 4)[0]
    require(0 < count <= 8, 'invalid fat architecture count')
    wide = data[:4] == b'\xca\xfe\xba\xbf'
    slices = []
    for index in range(count):
        entry = 8 + index * (32 if wide else 20)
        offset, length = struct.unpack_from('>QQ' if wide else '>II', data, entry + 8)
        require(offset + length <= len(data), 'truncated fat binary')
        slices.append(data[offset:offset + length])
    return slices


def macho_contract(path):
    """Fingerprint executable sections and load commands across re-signing.

    LC_CODE_SIGNATURE and __LINKEDIT sizes may change when replacing a signature;
    other commands, file-backed sections, and non-signature linkedit bytes may not.
    """
    contracts, plists = [], []
    for data in macho_slices(Path(path).read_bytes()):
        require(data[:4] == b'\xcf\xfa\xed\xfe' and len(data) >= 32, 'unsupported Mach-O slice')
        count, command_size = struct.unpack_from('<II', data, 16)
        require(32 + command_size <= len(data), 'truncated Mach-O commands')
        header = bytearray(data[:32]); header[16:24] = b'\0' * 8
        commands, sections = [], []
        linkedit = None
        signature_start = len(data)
        offset = 32
        for _ in range(count):
            kind, size = struct.unpack_from('<II', data, offset)
            require(size >= 8 and offset + size <= 32 + command_size, 'malformed Mach-O load command')
            block = bytearray(data[offset:offset + size])
            if kind == 0x1D:
                signature_start, signature_size = struct.unpack_from('<II', block, 8)
                require(signature_start + signature_size <= len(data), 'truncated signature blob')
            else:
                if kind == 0x19:
                    segment = bytes(block[8:24]).rstrip(b'\0')
                    file_offset, file_size = struct.unpack_from('<QQ', block, 40)
                    require(file_offset + file_size <= len(data), 'truncated Mach-O segment')
                    if segment == b'__LINKEDIT':
                        linkedit = file_offset
                        block[32:40] = b'\0' * 8
                        block[48:56] = b'\0' * 8
                    section_count = struct.unpack_from('<I', block, 64)[0]
                    for index in range(section_count):
                        section = 72 + index * 80
                        require(section + 80 <= size, 'malformed Mach-O section')
                        section_size = struct.unpack_from('<Q', block, section + 40)[0]
                        section_offset = struct.unpack_from('<I', block, section + 48)[0]
                        section_type = struct.unpack_from('<I', block, section + 64)[0] & 0xFF
                        if section_type in {1, 12, 18}:
                            continue
                        require(section_offset + section_size <= len(data), 'truncated Mach-O section')
                        contents = data[section_offset:section_offset + section_size]
                        sections.append(contents)
                        if bytes(block[section:section + 16]).rstrip(b'\0') == b'__info_plist':
                            plists.append(plistlib.loads(contents.rstrip(b'\0')))
                commands.append(bytes(block))
            offset += size
        require(offset == 32 + command_size, 'Mach-O command size mismatch')
        if linkedit is not None:
            require(signature_start >= linkedit, 'invalid signature location')
            sections.append(data[linkedit:signature_start].rstrip(b'\0'))
        contracts.append(hashlib.sha256(bytes(header) + b''.join(commands) + b''.join(sections)).hexdigest())
    return contracts, plists


def inspect_macho(path):
    architectures = sorted(run(['xcrun', 'lipo', '-archs', str(path)]).split())
    slices = {}
    for arch in architectures:
        output = run(['xcrun', 'otool', '-arch', arch, '-l', str(path)])
        dependencies, rpaths = [], []
        for block in re.split(r'Load command \d+\n', output)[1:]:
            kind = re.search(r'^\s*cmd (\S+)', block, re.M)
            require(kind is not None, 'missing Mach-O command name')
            if kind.group(1) in {'LC_LOAD_DYLIB', 'LC_LOAD_WEAK_DYLIB', 'LC_REEXPORT_DYLIB', 'LC_LOAD_UPWARD_DYLIB', 'LC_LAZY_LOAD_DYLIB'}:
                match = re.search(r'^\s*name (.+) \(offset \d+\)', block, re.M)
                require(match is not None, 'malformed dylib load command')
                dependencies.append(match.group(1))
            elif kind.group(1) == 'LC_RPATH':
                match = re.search(r'^\s*path (.+) \(offset \d+\)', block, re.M)
                require(match is not None, 'malformed rpath')
                rpaths.append(match.group(1))
            elif kind.group(1) in {'LC_LOAD_DYLINKER', 'LC_DYLD_ENVIRONMENT'}:
                require(kind.group(1) != 'LC_DYLD_ENVIRONMENT', 'embedded dyld environment forbidden')
                require('/usr/lib/dyld' in block, 'unexpected dynamic loader')
        symbols = run(['xcrun', 'nm', '-arch', arch, '-a', str(path)])
        slices[arch] = {'dependencies': dependencies, 'rpaths': rpaths, 'engine': bool(ENGINE.search(symbols + '\n' + '\n'.join(dependencies)))}
    payload, plists = macho_contract(path)
    return {'architectures': architectures, 'slices': slices, 'payload': payload, 'plists': plists}


def inside(root, path):
    resolved = path.resolve()
    require(resolved == root or root in resolved.parents, 'path escapes application')
    return resolved


def validate_closure(app, manifest, inspections):
    app = Path(app).resolve()
    objects = {item['target']: item for item in manifest['objects']}
    binaries = {inside(app, app / item['executable']): item for item in objects.values()}
    roots = manifest['systemDependencyRoots']

    def system(path):
        return any(path.startswith(root) for root in roots) and '..' not in Path(path).parts

    def expand(value, loader, executable):
        if value == '@loader_path' or value.startswith('@loader_path/'):
            return loader.parent / value.removeprefix('@loader_path').lstrip('/')
        if value == '@executable_path' or value.startswith('@executable_path/'):
            return executable.parent / value.removeprefix('@executable_path').lstrip('/')
        if value.startswith('/') and system(value):
            return Path(value)
        raise ValueError('unsafe dependency/runpath: ' + value)

    for name, item in objects.items():
        inspection = inspections[name]
        require(inspection['architectures'] == item['architectures'], 'wrong architecture: ' + name)
        for arch, data in inspection['slices'].items():
            require(data['engine'] == item['quickjs'], 'QuickJS engine ownership mismatch: ' + name)
            actual_rpaths = sorted(set(data['rpaths']))
            require(
                actual_rpaths == item['runpaths'],
                f'resolved Mach-O rpath drift for {name}: {actual_rpaths!r} differs from {item["runpaths"]!r}')
            loader = inside(app, app / item['executable'])
            host = item if item['role'] in {'app', 'worker', 'broker'} else next(obj for obj in objects.values() if obj['role'] == 'app')
            executable = inside(app, app / host['executable'])
            rpaths = [(value, loader) for value in data['rpaths']]
            if host['target'] != name:
                rpaths += [(value, executable) for value in inspections[host['target']]['slices'][arch]['rpaths']]
            expanded = []
            for value, owner in rpaths:
                resolved = expand(value, owner, executable).resolve()
                require(system(str(resolved)) or resolved == app or app in resolved.parents, 'runpath escapes application')
                expanded.append(resolved)
            for dependency in data['dependencies']:
                require(item['quickjs'] or not ENGINE.search(dependency), 'engine dependency outside worker')
                if system(dependency):
                    continue
                if dependency.startswith('@rpath/'):
                    candidates = {path / dependency[len('@rpath/'):] for path in expanded}
                else:
                    candidates = {expand(dependency, loader, executable)}
                matches = {path.resolve() for path in candidates if path.exists()}
                require(len(matches) == 1, 'unresolved/ambiguous dependency: ' + dependency)
                match = next(iter(matches))
                require(match in binaries, 'dependency is not declared code: ' + dependency)
                require(binaries[match]['target'] in item['dependencies'], 'undeclared link dependency: ' + dependency)


def signature_files(manifest):
    result = set()
    for item in manifest['objects']:
        prefix = '' if item['path'] == '.' else item['path'] + '/'
        if item['role'] == 'framework':
            result.add(prefix + 'Versions/A/_CodeSignature/CodeResources')
        elif item['role'] in {'app', 'broker'}:
            result.add(prefix + 'Contents/_CodeSignature/CodeResources')
    return result


def extended_attributes(path):
    # macOS Python distributions do not consistently expose os.listxattr.
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    list_attributes = library.listxattr
    list_attributes.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
    list_attributes.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)
    length = list_attributes(encoded, None, 0, 1)
    require(length >= 0, 'cannot inspect extended attributes')
    buffer = ctypes.create_string_buffer(length)
    require(list_attributes(encoded, buffer, length, 1) == length, 'extended attributes changed during inspection')
    names = [os.fsdecode(name) for name in buffer.raw.split(b'\0') if name]
    require(not set(names) & {'com.apple.ResourceFork', 'com.apple.FinderInfo'}, 'signing-sensitive extended attributes forbidden')
    read_attribute = library.getxattr
    read_attribute.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    read_attribute.restype = ctypes.c_ssize_t
    result = {}
    for name in sorted(names):
        length = read_attribute(encoded, os.fsencode(name), None, 0, 0, 1)
        require(length >= 0, 'cannot inspect extended attribute')
        buffer = ctypes.create_string_buffer(length)
        require(read_attribute(encoded, os.fsencode(name), buffer, length, 0, 1) == length, 'extended attribute changed during inspection')
        result[name] = hashlib.sha256(buffer.raw).hexdigest()
    return result


def validate_bundle(app, manifest, inspector=inspect_macho):
    validate_manifest(manifest)
    app = Path(app).resolve()
    require(app.is_dir(), 'application missing')
    expected, links = manifest['files'], manifest['symlinks']
    seals = signature_files(manifest)
    allowed = set(expected) | set(links) | seals
    declared_directories = set(manifest['directories'])
    directories = declared_directories | {
        str(parent) for name in allowed for parent in Path(name).parents if str(parent) != '.'}
    found = set()
    found_directories = set()
    snapshot = {}
    for folder, names, files in os.walk(app, followlinks=False):
        for name in sorted(names + files):
            path = Path(folder) / name
            relative = path.relative_to(app).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                require(relative in links and os.readlink(path) == links[relative], 'unexpected symbolic link: ' + relative)
                inside(app, path)
                require(path.exists(), 'broken symbolic link')
                found.add(relative)
                snapshot[relative] = {'link': links[relative], 'xattrs': extended_attributes(path)}
                continue
            require(stat.S_ISREG(mode) or stat.S_ISDIR(mode), 'special file forbidden')
            if stat.S_ISDIR(mode):
                require(relative in directories, 'undeclared directory: ' + relative)
                require(stat.S_IMODE(mode) == 0o755, 'unexpected directory mode')
                found_directories.add(relative)
                snapshot[relative] = {'mode': 0o755, 'xattrs': extended_attributes(path)}
                continue
            require(relative in allowed, 'undeclared file: ' + relative)
            require(path.stat().st_nlink == 1, 'hard-linked bundle file')
            found.add(relative)
            attributes = extended_attributes(path)
            snapshot[relative] = {'mode': stat.S_IMODE(mode), 'sha256': digest(path), 'xattrs': attributes}
            if relative in seals:
                require(stat.S_IMODE(mode) == 0o644, 'invalid resource seal mode')
                continue
            expectation = expected[relative]
            require(stat.S_IMODE(mode) == expectation['mode'], 'wrong file mode: ' + relative)
            magic = path.read_bytes()[:4]
            if expectation['kind'] == 'code':
                require(magic in MACH_MAGICS, 'expected Mach-O code: ' + relative)
            else:
                require(magic not in MACH_MAGICS and not mode & 0o111, 'executable resource forbidden')
            if 'sha256' in expectation:
                require(digest(path) == expectation['sha256'], 'resource content mismatch: ' + relative)
            if 'plist' in expectation:
                require(parsed_plist(path) == expectation['plist'], 'localized resource mismatch')
            if expectation['kind'] == 'plist':
                actual = plistlib.loads(path.read_bytes())
                require(all(actual.get(key) == value for key, value in expectation['values'].items()), 'plist identity/version mismatch: ' + relative)
    require((set(expected) | set(links)) <= found, 'missing manifest content: ' + ', '.join(sorted((set(expected) | set(links)) - found)))
    require(declared_directories <= found_directories, 'missing manifest directory: ' + ', '.join(sorted(declared_directories - found_directories)))
    inspections = {item['target']: inspector(app / item['executable']) for item in manifest['objects']}
    for item in manifest['objects']:
        if item['role'] == 'worker':
            plists = inspections[item['target']]['plists']
            require(len(plists) == len(item['architectures']), 'worker embedded plist missing')
            require(all(all(plist.get(key) == value for key, value in item['infoValues'].items()) for plist in plists), 'worker embedded identity mismatch')
    validate_closure(app, manifest, inspections)
    return {'inventory': snapshot, 'payloads': {key: value['payload'] for key, value in inspections.items()}}


def compare_inventory(before, after, manifest, signing=False):
    if not signing:
        require(before == after, 'sealed application changed')
        return
    require(before['payloads'] == after['payloads'], 'code payload changed while signing')
    code = {item['executable'] for item in manifest['objects']}
    seals = signature_files(manifest)
    seal_dirs = {str(Path(path).parent) for path in seals}
    def stable(snapshot):
        result = {}
        for path, value in snapshot['inventory'].items():
            if path in seals or path in seal_dirs:
                continue
            result[path] = {key: item for key, item in value.items() if not (path in code and key == 'sha256')}
        return result
    require(stable(before) == stable(after), 'resource/layout changed while signing')
