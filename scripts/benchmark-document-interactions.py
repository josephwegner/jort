#!/usr/bin/env python3
"""Capture independent-process baseline evidence; never recalibrate passing budgets."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--work-dir', type=Path, required=True)
parser.add_argument('--runs', type=int, default=5)
parser.add_argument('--resume', action='store_true')
args = parser.parse_args()
if args.runs < 5:
    parser.error('At least five independent processes per configuration are required')
env = dict(os.environ)
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
args.work_dir.mkdir(parents=True, exist_ok=True)
args.output.parent.mkdir(parents=True, exist_ok=True)

def output(*command):
    return subprocess.check_output(command, cwd=ROOT, env=env, text=True).strip()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

sources = sorted(p for folder in ('Sources', 'Tests', 'Jort') for p in (ROOT / folder).rglob('*')
                 if p.is_file() and p.suffix in ('.swift', '.m', '.h', '.c'))
source_hash = hashlib.sha256()
for path in sources:
    source_hash.update(str(path.relative_to(ROOT)).encode())
    source_hash.update(path.read_bytes())
report = {
    'schemaVersion': 1,
    'capturedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'sourceRevision': output('git', 'rev-parse', 'HEAD'),
    'sourceTreeSHA256': source_hash.hexdigest(),
    'sourceTreeDirty': bool(output('git', 'status', '--porcelain')),
    'environment': {
        'runnerClass': 'local-macos-arm64-document-baseline',
        'os': output('sw_vers'), 'architecture': platform.machine(),
        'hardwareModel': output('sysctl', '-n', 'hw.model'),
        'memoryBytes': int(output('sysctl', '-n', 'hw.memsize')),
        'cpu': output('sysctl', '-n', 'machdep.cpu.brand_string'),
        'xcode': output('xcodebuild', '-version'),
        'swift': output('xcrun', 'swift', '--version'),
    },
    'protocol': {
        'runsPerConfigurationPerSuite': args.runs,
        'configurations': ['Debug', 'Release'],
        'percentile': 'nearest-rank over post-warmup samples within each process',
        'poolProcesses': False, 'timingEnforcement': False,
        'testability': 'ENABLE_TESTABILITY=YES; Debug default, explicit for Release; optimization unchanged',
        'reason': 'Evidence collection only; existing test assertions and CI budgets are unchanged.',
        'warmup': 'Initial samples omitted only from structured distributions; original gates use all samples.',
    },
    'runs': [],
}
if args.output.exists():
    if not args.resume:
        parser.error('Output exists; use --resume to continue an interrupted capture')
    previous = json.loads(args.output.read_text())
    for field in ('sourceTreeSHA256', 'environment', 'protocol'):
        if previous[field] != report[field]:
            parser.error(f'Cannot resume: {field} changed')
    report = previous

suites = {
    'JortFoundation': [
        'JortFoundationTests/PerformanceTests/testRepresentativeDistributions',
        'JortFoundationTests/RunPerformanceTests/testCrawlLargeDocumentDistributions',
    ],
    'JortNativeTests': [
        'JortCoreTests/EditorTests/testSustainedEditingAutosaveScrollingAndBoundedUndo',
    ],
}
expected = {'JortFoundation': 10, 'JortNativeTests': 5}

def persist():
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')

for configuration in ('Debug', 'Release'):
    for scheme, tests in suites.items():
        completed = {row['processRun'] for row in report['runs']
                     if row['configuration'] == configuration and row['suite'] == scheme}
        if len(completed) == args.runs:
            continue
        common = [
            'xcodebuild', '-project', 'Jort.xcodeproj', '-scheme', scheme,
            '-configuration', configuration, '-destination', 'platform=macOS,arch=arm64',
            '-derivedDataPath', str(args.work_dir / configuration),
            'JORT_PERFORMANCE_ENFORCE=0', 'ENABLE_TESTABILITY=YES', '-parallel-testing-enabled', 'NO',
            *['-only-testing:' + test for test in tests],
        ]
        build_log = args.work_dir / f'{configuration}-{scheme}-build.log'
        print(f'Building {configuration} {scheme}', flush=True)
        with build_log.open('w') as log:
            subprocess.run([*common, 'build-for-testing'], cwd=ROOT, env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
        for index in range(args.runs):
            if index + 1 in completed:
                continue
            name = f'{configuration}-{scheme}-{index + 1}'
            log_path = args.work_dir / (name + '.log')
            print(f'Running {name}', flush=True)
            with log_path.open('w') as log:
                subprocess.run([*common, 'test-without-building'], cwd=ROOT, env=env,
                               stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
            records = []
            for line in log_path.read_text().splitlines():
                if line.startswith('JORT_DISTRIBUTION '):
                    records.append(json.loads(line.removeprefix('JORT_DISTRIBUTION ')))
            if len(records) != expected[scheme]:
                raise RuntimeError(f'{name}: expected {expected[scheme]} distributions, got {len(records)}')
            report['runs'].append({
                'configuration': configuration, 'suite': scheme, 'processRun': index + 1,
                'logSHA256': digest(log_path), 'distributions': records,
                'legacyReports': [line for line in log_path.read_text().splitlines()
                                  if line.startswith('PERF ')],
            })
            persist()
            print(f'Captured {name}: {len(records)} distributions', flush=True)
report['complete'] = True
persist()
print(f'Wrote {args.output}', flush=True)
