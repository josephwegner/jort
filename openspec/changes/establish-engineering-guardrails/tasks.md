## 1. Inventory and repository boundaries

- [ ] 1.1 Inventory tracked generated files, all current build/test/package output paths, and every tracked first-party Swift source root; record the exact cleanup scope before changing the index.
- [ ] 1.2 Normalize ignore rules for `build/`, `.build/`, `.build-*`, `dist/`, test results, Xcode user state, and any other confirmed derived paths while preserving all source-of-truth inputs.
- [ ] 1.3 Remove only the inventoried generated artifacts from the Git index without recursively deleting developers' local build output, then verify a clean checkout would not contain them.

## 2. Deterministic formatting baseline

- [ ] 2.1 Confirm the selected Xcode toolchain's `xcrun swift format` command and configuration schema, then add the committed formatter configuration and EditorConfig.
- [ ] 2.2 Add local format and format-check entry points that enumerate first-party Swift roots explicitly and exclude vendored, generated, and archived code.
- [ ] 2.3 Apply the formatter to the agreed first-party roots as a mechanical-only conversion and verify a second run produces no diff.
- [ ] 2.4 Add the formatter check and visible Xcode/Swift version reporting to CI.

## 3. Static-analysis signal

- [ ] 3.1 Configure and verify a blocking first-party analysis lane that covers every Jort-owned production target without emitting vendored QuickJS diagnostics.
- [ ] 3.2 Add a separate QuickJS analysis lane that retains the complete dependency report and exposes changes in its diagnostic set without globally suppressing analyzer findings.
- [ ] 3.3 Document the pinned QuickJS version/checksum relationship to the dependency audit and verify an intentional first-party diagnostic cannot be hidden by the vendored lane.

## 4. SQLite test ownership

- [ ] 4.1 Inventory tests and shared fixtures that create document, settings, history, registry, or composite SQLite-backed stores and identify their required close order.
- [ ] 4.2 Refactor those fixtures to retain and explicitly close every live store before scheduling temporary-directory removal, including failure and early-exit paths.
- [ ] 4.3 Verify teardown preserves primary test failures, reports secondary cleanup failures, and eliminates `vnode unlinked while in use` warnings from the native suite.

## 5. Verification and documentation

- [ ] 5.1 Document each local and CI verification command and classify it as blocking, informational, or conditionally enforced, including the separately owned known performance failure.
- [ ] 5.2 Run formatting verification, deterministic project generation, relevant headless/native tests, first-party analysis, the QuickJS audit lane, and `git diff --check`; record any remaining limitations without weakening existing gates.
