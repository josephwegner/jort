# Editor shell validation

Validated September 6, 2026 against `establish-editor-ui-shell` on the local macOS/Xcode host.

- Native AppKit suite: 19 tests passed, including shell sizing, footer rendering, Option state/lifecycle, native composition and word movement, line expansion/collapse, wrapping, edit anchoring, accessibility ordering, and viewport preservation.
- Document/persistence suite: 27 tests passed.
- Isolated application UI suite: 3 tests passed, including real Option hold/release events, Pocket, Find/Undo, and persistence across relaunch.
- The 10,000-line / 500-accessory test measured visible layout plus Option updates at approximately 0.19 ms p95, below the 100 ms regression ceiling. This measures visible refresh, not full accessory registration or end-to-end rendering latency.
- Project generation drift, packaging preservation checks, Swift 6 builds, and whitespace validation passed. A fresh unsigned local package is in `dist/Jort.app`.

Rendered native snapshots cover healthy/empty, populated landmarks, held Option, storage attention, a 460 × 300 window, and expanded lines. The full app screenshot from `testShellOptionRevealAndPocket` confirms native traffic lights, Pocket, a hidden visual title, separated gutter/footer, and no speculative Run controls. Snapshots are retained as Xcode test attachments; native fixtures also write to the system temporary `jort-shell-snapshots` directory.

Computer Use's native app entry point was unavailable in this session (`cua.getApp is not a function`); visual inspection used the actual app screenshot produced by the UI test runner and AppKit-rendered fixtures. A manual VoiceOver session was not performed; accessibility roles, values, and ordered line/accessory children are covered by native tests.

Accessory height uses TextKit 2 fragment bottom margins. Descriptors stay in AppKit and never enter canonical text or stored snapshots. No product feature registers them yet. Future Run features own their content, lifecycle, and persistence and consume the shared geometry.
