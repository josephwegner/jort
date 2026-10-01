"""Bounded, high-confidence secret checks for inputs to release artifacts.

Only known credential encodings and private-key headers are recognized. This
is a release guard, not a claim to detect every arbitrary user-chosen password.
Diagnostics deliberately contain neither filenames nor matching bytes.
"""
import re
from pathlib import Path

from release_manifest import canonical, require, safe_path

MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_REPOSITORY_BYTES = 512 * 1024 * 1024
MAX_FILES = 100000
SECRET_PATTERNS = (
    rb'-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----',
    rb'\bsk-or-v1-[0-9a-fA-F]{64}\b',
    rb'\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{60,255})\b',
    rb'\bxox[baprs]-[0-9]{10,}-[A-Za-z0-9-]{20,}\b',
    rb'\bAKIA[0-9A-Z]{16}\b',
    # JWTs used as literal bearer credentials, rather than documentation words.
    rb'(?i)\bBearer[ \t]+eyJ[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}',
)
SECRET_MATCHERS = tuple(re.compile(pattern) for pattern in SECRET_PATTERNS)


def scan_bytes(data):
    require(len(data) <= MAX_FILE_BYTES, 'release input exceeds secret-scan bound')
    require(not any(pattern.search(data) for pattern in SECRET_MATCHERS),
            'secret-looking release input rejected; inspect inputs locally')


def scan_manifest(manifest):
    scan_bytes(canonical(manifest))
    sensitive_fields = {'apikey', 'accesstoken', 'refreshtoken', 'password', 'passwd',
                        'privatekey', 'authorization', 'clientsecret'}
    def inspect(value, depth=0):
        require(depth <= 64, 'release input exceeds nesting bound')
        if isinstance(value, dict):
            for key, child in value.items():
                normalized = re.sub(r'[^a-z]', '', key.lower())
                require(normalized not in sensitive_fields or child in (None, ''),
                        'secret-looking manifest field rejected; inspect inputs locally')
                inspect(child, depth + 1)
        elif isinstance(value, list):
            for child in value:
                inspect(child, depth + 1)
    inspect(manifest)


def scan_repository(root, tracked):
    root = Path(root).resolve()
    paths = tracked.split(b'\0')
    require(len(paths) <= MAX_FILES + 1, 'release repository exceeds secret-scan file bound')
    total = 0
    for raw_path in paths:
        if not raw_path:
            continue
        try:
            relative = raw_path.decode('utf-8')
        except UnicodeDecodeError:
            raise ValueError('release input filename must be UTF-8') from None
        safe_path(relative)
        path = root / relative
        require(path.resolve().is_relative_to(root), 'release input escapes source tree')
        require(path.is_file(), 'release input is not a regular file')
        size = path.stat().st_size
        total += size
        require(size <= MAX_FILE_BYTES and total <= MAX_REPOSITORY_BYTES,
                'release repository exceeds secret-scan byte bound')
        with path.open('rb') as stream:
            scan_bytes(stream.read(MAX_FILE_BYTES + 1))
