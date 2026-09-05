# Initial regression budgets

The committed `canvas-10000.txt` fixture contains 10,000 representative lines with ASCII, Japanese, combining-language text, and emoji. CI reports p50/p95/p99 edits and p95 serialization rather than a single append timing. `JORT_PERFORMANCE_ENFORCE=1` enables coarse regression gates on the standard non-sanitized CI runner.

| Workflow | Initial budget |
|---|---|
| Launch to editable, healthy fixture store | 2 seconds |
| 10k-line transaction, p95 | 100 ms debug regression ceiling; target under 16 ms optimized |
| Save serialization, p95 | 250 ms |
| Large paste (10k lines) | 2 seconds |
| Viewport/gutter layout | 33 ms target, 100 ms regression ceiling |
| Native sustained edits with saves | p95 below 100 ms |
| Undo depth | 200 groups bounded; verify 100 randomized native edit/undo/redo cycles |
| Search / replace-all | 1 second target for the fixture |
| Memory growth | 200 MB ceiling for the fixture and bounded undo, excluding platform/test-runner baseline |
| Future history checkpoint | 250 ms target; history does not exist yet |

These are initial generous regression ceilings for shared macOS runners, not product latency promises. Sanitizer runs report functional results separately and do not enforce timing ceilings. The save-cadence test measures persistence during sustained typing without an idle gap. Scheduling, storage latency, and failure retries mean there is no strict user-facing half-second deadline.

Transaction deltas expose inserted/deleted IDs and before/after immutable snapshots. Full snapshots, offset shifting, and bounded undo snapshots remain intentionally simple until workflow measurements justify more complex structures. Resident-memory and physical-IME characterization still require representative hardware; targets in the table that are not yet instrumented are explicitly targets, not claimed measurements.
