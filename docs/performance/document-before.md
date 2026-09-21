# Before-change document performance

The flat live document model is unchanged. Results include the instrumentation
from task 1.1 and retain the existing timing ceilings. This is an evidence run
with timing enforcement disabled; passing XCTest does not imply passing timing budgets.

Five independent processes ran serially for each suite and configuration.
Each cell below uses process-level percentiles: medians summarize the five
process values, and the p95 range shows their minimum and maximum. Samples
are never pooled across processes or build configurations.

The raw JSON records every measured sample, warm-up/sample counts, UTF-8
fixture hashes, source hash, hardware, OS, Swift and Xcode versions.
Release uses -O with ENABLE_TESTABILITY=YES for the existing @testable imports.
Debug uses -Onone. No application optimization flags or CI ceilings were changed.

The structured report uses nearest-rank percentiles after declared warm-up.
Existing XCTest gates still use their original sample sets and percentile formulas.
For small sample sets p99 is the maximum; it is not a precise tail estimate.

Native edit includes the adapter and synchronous observers. Viewport layout is
the existing explicit layout/gutter workflow, not deferred decoration convergence.
Save-and-recovery includes encode, SQLite verification and recovery publication.
Restore-and-save includes transaction acceptance and durable save. Isolated
signpost acceptance/first-paint/convergence distributions remain task 7.3.

## Debug

| Fixture / operation | p50 median (ms) | p95 median (ms) | p99 median (ms) | p95 range (ms) |
| --- | ---: | ---: | ---: | ---: |
| canvas-10000 / native-edit | 181.892 | 231.265 | 250.914 | 212.414–242.881 |
| canvas-10000 / native-navigation | 2.152 | 2.638 | 2.670 | 2.531–2.678 |
| canvas-10000 / save-and-recovery | 338.680 | 348.093 | 348.093 | 344.277–351.072 |
| canvas-10000 / serialization | 72.473 | 74.875 | 74.875 | 73.719–76.587 |
| canvas-10000 / transaction | 35.858 | 37.302 | 39.338 | 37.065–37.829 |
| canvas-10000 / viewport-layout | 1.272 | 1.720 | 1.762 | 1.650–1.746 |
| crawl-million / history-compare | 212.735 | 217.586 | 217.586 | 215.316–219.785 |
| crawl-million / history-decode | 517.036 | 536.254 | 536.254 | 524.256–546.132 |
| crawl-million / history-list | 0.319 | 0.377 | 0.377 | 0.359–0.536 |
| crawl-million / history-prune | 0.502 | 1.854 | 1.854 | 1.644–2.782 |
| crawl-million / history-retain | 870.763 | 906.892 | 906.892 | 882.185–911.824 |
| crawl-million / restore-and-save | 818.855 | 855.152 | 855.152 | 841.250–866.369 |
| crawl-million / search | 9.426 | 24.927 | 24.927 | 24.072–25.252 |

## Release

| Fixture / operation | p50 median (ms) | p95 median (ms) | p99 median (ms) | p95 range (ms) |
| --- | ---: | ---: | ---: | ---: |
| canvas-10000 / native-edit | 142.246 | 268.302 | 277.406 | 261.763–276.129 |
| canvas-10000 / native-navigation | 2.237 | 2.752 | 2.868 | 2.560–2.810 |
| canvas-10000 / save-and-recovery | 289.415 | 299.323 | 299.323 | 296.710–300.679 |
| canvas-10000 / serialization | 65.782 | 67.454 | 67.454 | 66.109–69.565 |
| canvas-10000 / transaction | 25.597 | 26.742 | 27.870 | 26.594–26.946 |
| canvas-10000 / viewport-layout | 1.304 | 1.782 | 1.882 | 1.654–1.924 |
| crawl-million / history-compare | 148.261 | 150.855 | 150.855 | 150.564–155.317 |
| crawl-million / history-decode | 474.294 | 479.518 | 479.518 | 477.781–485.529 |
| crawl-million / history-list | 0.266 | 0.311 | 0.311 | 0.292–0.381 |
| crawl-million / history-prune | 0.479 | 2.018 | 2.018 | 1.865–3.239 |
| crawl-million / history-retain | 789.490 | 817.716 | 817.716 | 804.156–821.298 |
| crawl-million / restore-and-save | 719.002 | 741.452 | 741.452 | 721.964–751.209 |
| crawl-million / search | 8.175 | 17.989 | 17.989 | 17.970–18.414 |

## Reproduction

Run python3 scripts/benchmark-document-interactions.py --output <new-report.json>
--work-dir <fresh-work-directory> --runs 5 from the repository root.
Use --resume only for an interrupted capture with identical source/environment.
Do not run other builds or benchmarks concurrently with timing capture.

The reference runner definition is in document-environment.json; a different
machine must not silently replace this baseline or derive a new passing ceiling.
Budget changes require a separate explicit manifest diff with measured rationale.
