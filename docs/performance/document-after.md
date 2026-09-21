# Post-change document performance

Five independent processes per suite and configuration ran serially on the same checked reference runner. Tables summarize process percentiles without pooling samples. Raw samples, fixture hashes, source-tree hash, environment, and warm-up counts are in `document-after.json`; the original evidence remains in `document-before.json`.

Timing enforcement was disabled for evidence collection. Successful benchmark tests do not mean every timing ceiling passed. No timing budgets or relative regression allowances were changed. Debug uses -Onone and Release uses -O with testability enabled. For the small measured sample sets, p99 is the observed maximum rather than a well-resolved tail estimate.

Native edit measures synchronous acceptance; first paint measures the next native draw for an accepted revision; prepared convergence measures drained presentation work for the current epoch. The latter two are new measurements and have no before-change distribution. Background operations include full validation, materialization, and durable work as named.

## Debug

| Fixture / operation | p50 median ms | p95 median ms | p99 median ms | p95 process range ms | Before p95 ms | Change ms (%) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| canvas-10000 / native-edit | 2.555 | 3.217 | 3.504 | 3.071–3.408 | 231.265 | -228.049 (-98.6%) |
| canvas-10000 / native-first-paint | 4.806 | 5.642 | 5.814 | 5.599–6.000 | — | New metric |
| canvas-10000 / native-navigation | 2.181 | 2.651 | 2.775 | 2.527–2.833 | 2.638 | +0.013 (+0.5%) |
| canvas-10000 / prepared-convergence | 8.648 | 9.854 | 10.061 | 9.742–10.047 | — | New metric |
| canvas-10000 / save-and-recovery | 728.921 | 738.257 | 738.257 | 734.120–742.901 | 348.093 | +390.165 (+112.1%) |
| canvas-10000 / serialization | 111.455 | 114.020 | 114.020 | 112.556–121.495 | 74.875 | +39.145 (+52.3%) |
| canvas-10000 / transaction | 0.812 | 1.107 | 1.209 | 1.057–1.138 | 37.302 | -36.195 (-97.0%) |
| canvas-10000 / viewport-layout | 1.058 | 1.460 | 1.601 | 1.380–1.586 | 1.720 | -0.260 (-15.1%) |
| crawl-million / history-compare | 1014.678 | 1031.052 | 1031.052 | 1026.264–1037.844 | 217.586 | +813.466 (+373.9%) |
| crawl-million / history-decode | 971.813 | 984.954 | 984.954 | 979.593–990.574 | 536.254 | +448.700 (+83.7%) |
| crawl-million / history-list | 0.300 | 0.338 | 0.338 | 0.329–0.417 | 0.377 | -0.039 (-10.4%) |
| crawl-million / history-prune | 0.481 | 2.768 | 2.768 | 2.171–2.893 | 1.854 | +0.914 (+49.3%) |
| crawl-million / history-retain | 1455.099 | 1475.287 | 1475.287 | 1468.671–1503.266 | 906.892 | +568.395 (+62.7%) |
| crawl-million / restore-and-save | 1715.569 | 1746.132 | 1746.132 | 1736.199–1748.586 | 855.152 | +890.980 (+104.2%) |
| crawl-million / search | 66.547 | 75.662 | 75.662 | 73.894–85.637 | 24.927 | +50.736 (+203.5%) |

## Release

| Fixture / operation | p50 median ms | p95 median ms | p99 median ms | p95 process range ms | Before p95 ms | Change ms (%) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| canvas-10000 / native-edit | 1.292 | 1.709 | 1.794 | 1.640–2.536 | 268.302 | -266.593 (-99.4%) |
| canvas-10000 / native-first-paint | 3.469 | 4.060 | 4.512 | 4.005–5.964 | — | New metric |
| canvas-10000 / native-navigation | 2.104 | 2.669 | 2.884 | 2.501–2.727 | 2.752 | -0.083 (-3.0%) |
| canvas-10000 / prepared-convergence | 7.315 | 8.225 | 8.431 | 7.849–10.379 | — | New metric |
| canvas-10000 / save-and-recovery | 537.911 | 548.841 | 548.841 | 542.787–556.344 | 299.323 | +249.519 (+83.4%) |
| canvas-10000 / serialization | 103.465 | 105.363 | 105.363 | 104.294–111.173 | 67.454 | +37.909 (+56.2%) |
| canvas-10000 / transaction | 0.230 | 0.353 | 0.419 | 0.318–0.370 | 26.742 | -26.389 (-98.7%) |
| canvas-10000 / viewport-layout | 0.961 | 1.454 | 1.551 | 1.382–1.627 | 1.782 | -0.328 (-18.4%) |
| crawl-million / history-compare | 536.312 | 551.209 | 551.209 | 540.888–560.951 | 150.855 | +400.355 (+265.4%) |
| crawl-million / history-decode | 759.758 | 770.468 | 770.468 | 765.731–787.260 | 479.518 | +290.950 (+60.7%) |
| crawl-million / history-list | 0.270 | 0.333 | 0.333 | 0.293–0.387 | 0.311 | +0.022 (+7.1%) |
| crawl-million / history-prune | 0.463 | 2.614 | 2.614 | 1.496–2.704 | 2.018 | +0.595 (+29.5%) |
| crawl-million / history-retain | 1199.512 | 1222.078 | 1222.078 | 1211.043–1237.848 | 817.716 | +404.362 (+49.5%) |
| crawl-million / restore-and-save | 1191.202 | 1209.584 | 1209.584 | 1205.864–1241.309 | 741.452 | +468.132 (+63.1%) |
| crawl-million / search | 59.601 | 66.550 | 66.550 | 64.523–70.655 | 17.989 | +48.561 (+269.9%) |

## Rollout gate and measured limitations

The final rollout task remains open. Median process p95 for save-and-recovery
is 738.257 ms in Debug and 548.841 ms in Release, exceeding the unchanged 250 ms
ceiling in every measured process. The baseline already exceeded that ceiling,
but this implementation further regresses the operation by 112.1% and 83.4%.
No budget increase or self-calibrating allowance is proposed.

Native edit acceptance improves 98.6% in Debug and 99.4% in Release and is below
its 100 ms ceiling in every measured process. New first-paint and convergence
metrics are observations, not newly approved budgets. Background serialization,
search, history decode/compare/retain and restore have measurable regressions;
see the full table rather than interpreting fast input as faster overall storage.
The evidence identifies an optimization requirement, not a validated cause:
profile full materialization, index reconstruction and history comparison before
changing those complete-validation boundaries.

Correctness/structural verification passed: 203 Foundation/contract/runtime tests,
131 native tests and 7 UI tests, plus formatting, generated-project parity,
localization, first-party analysis and strict OpenSpec validation. These successes
do not waive the outstanding hardware timing gate.

## Reproduction

`python3 scripts/benchmark-document-interactions.py --output <new-report.json> --work-dir <fresh-directory> --runs 5`

Use `--resume` only with the same source, environment and protocol. Run no concurrent builds or benchmarks during capture. The reference runner and unchanged ceilings are in `document-environment.json`.
