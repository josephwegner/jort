#!/usr/bin/env python3
"""Validate a run-owned local stage before atomically replacing the local app."""
import argparse
import ctypes
import os
from pathlib import Path
import shutil
import tempfile

from release_manifest import load, require
from release_validation import validate_bundle


def atomic_swap(staged, destination):
    if destination.exists():
        libc = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
        swap = libc.renameatx_np
        swap.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        if swap(-2, os.fsencode(staged), -2, os.fsencode(destination), 2) != 0:
            raise OSError(ctypes.get_errno(), 'Atomic app swap failed')
    else:
        os.rename(staged, destination)


def package(source, destination, manifest, validator=validate_bundle, swap=atomic_swap):
    source, destination = Path(source).resolve(), Path(destination).absolute()
    require(source.is_dir() and source.suffix == '.app', 'invalid source application')
    require(destination.name == 'Jort.app' and not destination.is_symlink(), 'invalid local destination')
    require(source != destination and source not in destination.parents and destination not in source.parents, 'overlapping package paths')
    destination.parent.mkdir(parents=True, exist_ok=True)
    require(destination.parent.resolve() == destination.parent, 'linked destination directory')
    staging = Path(tempfile.mkdtemp(prefix='.jort-stage-', dir=destination.parent))
    try:
        staged = staging / 'Jort.app'
        shutil.copytree(source, staged, symlinks=True)
        validator(staged, manifest)
        swap(staged, destination)
    finally:
        shutil.rmtree(staging)
    print(f'Built {destination} — local-only, not a distribution artifact.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--manifest', required=True, type=Path)
    args = parser.parse_args()
    package(args.source, args.destination, load(args.manifest))
