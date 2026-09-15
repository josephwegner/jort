#!/usr/bin/env python3
"""Format or check tracked first-party Swift plus new files in the same roots."""
import argparse
import concurrent.futures
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
ROOTS = ('Jort', 'Sources', 'Tests', 'Tools')
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
env = dict(os.environ)
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
paths = subprocess.check_output(
    ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', *ROOTS],
    cwd=ROOT).decode().split('\0')
paths = sorted({p for p in paths if p.endswith('.swift') and (ROOT / p).is_file()})
# Fail if a new tracked Swift root is introduced without an explicit policy decision.
all_tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
unknown = [p for p in all_tracked if p.endswith('.swift') and p.split('/')[0] not in ROOTS
           and not p.startswith(('Vendor/', 'openspec/', 'build-jort-v1/'))]
if unknown:
    sys.exit('Unclassified Swift sources: ' + ', '.join(unknown))

def format_file(path):
    command = ['xcrun', 'swift', 'format', 'format', '--configuration', str(ROOT / '.swift-format')]
    if not args.check:
        command.append('--in-place')
    result = subprocess.run([*command, path], cwd=ROOT, env=env, capture_output=True)
    if result.returncode:
        print(result.stderr.decode(), file=sys.stderr)
        return False
    if args.check and result.stdout != (ROOT / path).read_bytes():
        print('Formatting differs: ' + path, file=sys.stderr)
        return False
    return True

with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    results = list(pool.map(format_file, paths))
print(f'{"Checked" if args.check else "Formatted"} {len(paths)} first-party Swift files.')
sys.exit(0 if all(results) else 1)
