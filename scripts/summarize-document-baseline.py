#!/usr/bin/env python3
"""Summarize process distributions without pooling samples or changing budgets."""
import argparse
import collections
import json
from pathlib import Path
import statistics

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('report', type=Path)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
data = json.loads(args.report.read_text())
if not data.get('complete'):
    parser.error('Baseline capture is incomplete')
groups = collections.defaultdict(list)
for run in data['runs']:
    for record in run['distributions']:
        groups[(run['configuration'], record['fixture'], record['metric'])].append(record)
lines = [
    '# Before-change document performance', '',
    'The flat live document model is unchanged. Results include the instrumentation',
    'from task 1.1 and retain the existing timing ceilings. This is an evidence run',
    'with timing enforcement disabled; passing XCTest does not imply passing timing budgets.', '',
    'Five independent processes ran serially for each suite and configuration.',
    'Each cell below uses process-level percentiles: medians summarize the five',
    'process values, and the p95 range shows their minimum and maximum. Samples',
    'are never pooled across processes or build configurations.', '',
    'The raw JSON records every measured sample, warm-up/sample counts, UTF-8',
    'fixture hashes, source hash, hardware, OS, Swift and Xcode versions.',
    'Release uses -O with ENABLE_TESTABILITY=YES for the existing @testable imports.',
    'Debug uses -Onone. No application optimization flags or CI ceilings were changed.', '',
    'The structured report uses nearest-rank percentiles after declared warm-up.',
    'Existing XCTest gates still use their original sample sets and percentile formulas.',
    'For small sample sets p99 is the maximum; it is not a precise tail estimate.', '',
    'Native edit includes the adapter and synchronous observers. Viewport layout is',
    'the existing explicit layout/gutter workflow, not deferred decoration convergence.',
    'Save-and-recovery includes encode, SQLite verification and recovery publication.',
    'Restore-and-save includes transaction acceptance and durable save. Isolated',
    'signpost acceptance/first-paint/convergence distributions remain task 7.3.', '',
]
for configuration in ['Debug', 'Release']:
    lines += [f'## {configuration}', '',
              '| Fixture / operation | p50 median (ms) | p95 median (ms) | p99 median (ms) | p95 range (ms) |',
              '| --- | ---: | ---: | ---: | ---: |']
    for (config, fixture, metric), records in sorted(groups.items()):
        if config != configuration:
            continue
        if len(records) != 5:
            parser.error(f'Expected five processes for {config}/{metric}')
        p50, p95, p99 = [[r[key] for r in records] for key in ['p50Ms', 'p95Ms', 'p99Ms']]
        lines.append(f'| {fixture} / {metric} | {statistics.median(p50):.3f} | '
                     f'{statistics.median(p95):.3f} | {statistics.median(p99):.3f} | '
                     f'{min(p95):.3f}–{max(p95):.3f} |')
    lines.append('')
lines += [
    '## Reproduction', '',
    'Run python3 scripts/benchmark-document-interactions.py --output <new-report.json>',
    '--work-dir <fresh-work-directory> --runs 5 from the repository root.',
    'Use --resume only for an interrupted capture with identical source/environment.',
    'Do not run other builds or benchmarks concurrently with timing capture.', '',
    'The reference runner definition is in document-environment.json; a different',
    'machine must not silently replace this baseline or derive a new passing ceiling.',
    'Budget changes require a separate explicit manifest diff with measured rationale.',
]
args.output.write_text('\n'.join(lines) + '\n')
