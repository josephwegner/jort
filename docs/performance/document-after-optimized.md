# Post-change document performance

Five independent processes per suite and configuration ran serially on the same checked reference runner. Tables summarize process percentiles without pooling samples. Raw samples, fixture hashes, source-tree hash, environment, and warm-up counts are in `document-after-optimized.json`; the original evidence remains in `document-before.json`.

Timing enforcement was disabled for evidence collection. Successful benchmark tests do not mean every timing ceiling passed. No timing budgets or relative regression allowances were changed. Debug uses -Onone and Release uses -O with testability enabled. For the small measured sample sets, p99 is the observed maximum rather than a well-resolved tail estimate.

Native edit measures synchronous acceptance; first paint measures the next native draw for an accepted revision; prepared convergence measures drained presentation work for the current epoch. The latter two are new measurements and have no before-change distribution. Background operations include full validation, materialization, and durable work as named.

The intermediate capture in `document-after.json` showed save-and-recovery p95
of 738.257 ms in Debug and 548.841 ms in Release. Phase timing attributed the
cost to three redundant full decodes of bytes just produced by the validated
encoder: SQLite readback, retained-checkpoint verification, and new-checkpoint
verification. Exact byte equality/checksum now verifies publication, while load
and recovery retain full decode and validation. The final save-and-recovery p95
is 120.733 ms in Debug and 109.036 ms in Release; all five processes are below
the unchanged 250 ms ceiling.

History decode, comparison, retention, and search remain slower than the flat
baseline. They have no changed or self-calibrating allowance in this change;
their distributions remain visible below as follow-up optimization targets.

## Debug

| Fixture / operation | p50 median ms | p95 median ms | p99 median ms | p95 process range ms | Before p95 ms | Change ms (%) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| canvas-10000 / native-edit | 2.529 | 3.110 | 3.276 | 2.989–3.213 | 231.265 | -228.155 (-98.7%) |
| canvas-10000 / native-first-paint | 4.800 | 5.610 | 5.727 | 5.406–5.822 | — | New metric |
| canvas-10000 / native-navigation | 2.174 | 2.649 | 2.977 | 2.369–2.863 | 2.638 | +0.011 (+0.4%) |
| canvas-10000 / prepared-convergence | 8.749 | 9.856 | 10.307 | 9.787–10.599 | — | New metric |
| canvas-10000 / save-and-recovery | 119.219 | 120.733 | 120.733 | 120.478–126.676 | 348.093 | -227.360 (-65.3%) |
| canvas-10000 / serialization | 114.695 | 117.425 | 117.425 | 115.950–125.178 | 74.875 | +42.550 (+56.8%) |
| canvas-10000 / transaction | 0.820 | 1.172 | 1.269 | 1.103–1.195 | 37.302 | -36.129 (-96.9%) |
| canvas-10000 / viewport-layout | 1.028 | 1.451 | 1.540 | 1.419–1.606 | 1.720 | -0.270 (-15.7%) |
| crawl-million / history-compare | 1037.420 | 1056.195 | 1056.195 | 1050.859–1064.673 | 217.586 | +838.609 (+385.4%) |
| crawl-million / history-decode | 851.118 | 866.066 | 866.066 | 854.127–871.832 | 536.254 | +329.812 (+61.5%) |
| crawl-million / history-list | 0.302 | 0.403 | 0.403 | 0.314–0.435 | 0.377 | +0.027 (+7.1%) |
| crawl-million / history-prune | 0.464 | 1.756 | 1.756 | 1.335–1.839 | 1.854 | -0.098 (-5.3%) |
| crawl-million / history-retain | 1350.986 | 1374.056 | 1374.056 | 1364.261–1413.752 | 906.892 | +467.164 (+51.5%) |
| crawl-million / restore-and-save | 503.004 | 516.247 | 516.247 | 510.807–519.225 | 855.152 | -338.905 (-39.6%) |
| crawl-million / search | 70.645 | 77.345 | 77.345 | 76.043–81.724 | 24.927 | +52.419 (+210.3%) |

## Release

| Fixture / operation | p50 median ms | p95 median ms | p99 median ms | p95 process range ms | Before p95 ms | Change ms (%) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| canvas-10000 / native-edit | 1.320 | 1.620 | 1.676 | 1.493–1.811 | 268.302 | -266.682 (-99.4%) |
| canvas-10000 / native-first-paint | 3.534 | 3.978 | 4.141 | 3.878–4.561 | — | New metric |
| canvas-10000 / native-navigation | 2.121 | 2.578 | 2.764 | 2.356–2.929 | 2.752 | -0.174 (-6.3%) |
| canvas-10000 / prepared-convergence | 7.290 | 8.088 | 8.476 | 7.695–8.345 | — | New metric |
| canvas-10000 / save-and-recovery | 107.786 | 109.036 | 109.036 | 107.244–110.543 | 299.323 | -190.286 (-63.6%) |
| canvas-10000 / serialization | 103.020 | 105.102 | 105.102 | 104.068–106.944 | 67.454 | +37.648 (+55.8%) |
| canvas-10000 / transaction | 0.218 | 0.326 | 0.414 | 0.311–0.371 | 26.742 | -26.416 (-98.8%) |
| canvas-10000 / viewport-layout | 0.976 | 1.440 | 1.480 | 1.253–1.599 | 1.782 | -0.342 (-19.2%) |
| crawl-million / history-compare | 532.346 | 539.591 | 539.591 | 533.839–547.440 | 150.855 | +388.737 (+257.7%) |
| crawl-million / history-decode | 696.904 | 705.070 | 705.070 | 702.935–708.284 | 479.518 | +225.552 (+47.0%) |
| crawl-million / history-list | 0.261 | 0.321 | 0.321 | 0.290–0.400 | 0.311 | +0.010 (+3.3%) |
| crawl-million / history-prune | 0.414 | 1.502 | 1.502 | 1.431–1.683 | 2.018 | -0.516 (-25.6%) |
| crawl-million / history-retain | 1132.091 | 1150.476 | 1150.476 | 1139.233–1158.196 | 817.716 | +332.760 (+40.7%) |
| crawl-million / restore-and-save | 347.552 | 355.416 | 355.416 | 353.961–364.842 | 741.452 | -386.036 (-52.1%) |
| crawl-million / search | 58.576 | 64.459 | 64.459 | 64.258–65.570 | 17.989 | +46.470 (+258.3%) |

## Reproduction

`python3 scripts/benchmark-document-interactions.py --output <new-report.json> --work-dir <fresh-directory> --runs 5`

Use `--resume` only with the same source, environment and protocol. Run no concurrent builds or benchmarks during capture. The reference runner and unchanged ceilings are in `document-environment.json`.
