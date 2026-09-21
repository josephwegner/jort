#!/usr/bin/env python3
"""Run isolated representation prototypes; do not run concurrently with timing capture."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--work-dir', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.work_dir.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
lines = []
for index in range(25000):
    prefix = ' \t ' if index % 19 == 0 else f'{index} 日本語 🦊 e\u0301 thought '
    length = 40 if index == 24999 else 39
    lines.append(prefix + ' ' * (length - len(prefix.encode('utf-16-le')) // 2))
crawl = args.work_dir / 'crawl-million.txt'
crawl.write_text('\n'.join(lines))
assert hashlib.sha256(crawl.read_bytes()).hexdigest() == '764b919884b54c7065111cb3ff506580fac6bb17a175d0e17d2f69358245a301'
source = ROOT / 'scripts/diagnostics/document-sequence-probe.swift'
report = {
    'schemaVersion': 1, 'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'scope': 'Sequence primitives, not end-to-end document transactions. Full-width 128-bit stable test IDs and bounded UTF-16 chunk roots. Transaction metadata and native integration are not measured here.',
    'allocationEstimate': 'Node payload estimates exclude allocator overhead. Peak resident bytes include property checks and 200 retained snapshots.',
    'results': [],
}
for configuration, optimization in [('Debug', '-Onone'), ('Release', '-O')]:
    binary = args.work_dir / ('sequence-' + configuration)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', optimization,
                    '-module-cache-path', str(args.work_dir / 'module-cache'),
                    str(source), '-o', str(binary)], cwd=ROOT, env=env, check=True)
    for fixture in [ROOT / 'Tests/Fixtures/canvas-10000.txt', crawl]:
        for fanout, leaf_capacity in [(0, 0), (16, 16), (32, 32)]:
            print(f'{configuration} {fixture.name} fanout={fanout}', flush=True)
            result = subprocess.run([str(binary), str(fanout), str(leaf_capacity), str(fixture)],
                                    capture_output=True, text=True, check=True, timeout=300)
            record = json.loads(result.stdout)
            record.update(configuration=configuration, fixtureSHA256=hashlib.sha256(fixture.read_bytes()).hexdigest())
            report['results'].append(record)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
