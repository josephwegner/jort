## ADDED Requirements

### Requirement: Generated artifacts remain outside version control
Jort's repository SHALL exclude generated build products, derived data, test results, local distribution artifacts, and Xcode user state from version control while retaining all source-of-truth project and packaging inputs.

#### Scenario: Clean checkout is inspected
- **WHEN** a clean checkout is compared with the tracked file list
- **THEN** no generated build product, derived-data database, compiled framework, application bundle, test result, or local distribution artifact is tracked
- **AND** `project.yml`, scripts, source resources, fixtures, and other inputs required to reproduce those artifacts remain tracked

#### Scenario: Developer builds locally
- **WHEN** local build, test, analysis, or packaging commands create derived output in a documented repository path
- **THEN** Git ignores that output
- **AND** the cleanup migration does not require deleting the developer's existing untracked local output

### Requirement: First-party Swift formatting is deterministic and enforced
Jort SHALL define one committed EditorConfig and Swift formatter policy for first-party Swift sources, SHALL exclude vendored and generated sources from automatic formatting, and SHALL enforce that policy using the selected project toolchain.

#### Scenario: Formatted checkout is checked
- **WHEN** the formatter check runs against every tracked first-party Swift source root
- **THEN** it exits successfully without changing files
- **AND** a second formatting run produces no diff

#### Scenario: Formatting violation is introduced
- **WHEN** a first-party Swift source violates the committed formatter policy
- **THEN** the local and CI formatter checks fail with the affected file identified
- **AND** vendored QuickJS sources are not rewritten as part of the fix

#### Scenario: Toolchain selection changes
- **WHEN** CI runs formatting under a selected Xcode and Swift toolchain
- **THEN** the toolchain versions are visible in check output
- **AND** formatter-output changes caused by a toolchain upgrade are handled as an explicit mechanical update rather than mixed into behavioral work

### Requirement: Static analysis separates first-party and vendored signal
Jort SHALL run a blocking first-party static-analysis lane whose result is not obscured or determined by vendored QuickJS diagnostics and SHALL retain a separate auditable analysis result for the pinned QuickJS dependency.

#### Scenario: First-party analysis is clean
- **WHEN** analyzer findings exist only in vendored QuickJS
- **THEN** the first-party analysis lane reports no first-party diagnostics
- **AND** the complete QuickJS diagnostic report remains available in its separate audit lane

#### Scenario: First-party analyzer finding is introduced
- **WHEN** the analyzer reports a diagnostic in Jort-owned source
- **THEN** the blocking first-party lane fails and identifies the source location
- **AND** a vendored diagnostic baseline cannot suppress or reclassify that finding

#### Scenario: Vendored analyzer output changes
- **WHEN** the pinned QuickJS source or analyzer toolchain produces a different diagnostic set
- **THEN** the dependency audit exposes the change for review
- **AND** no global analyzer suppression hides the changed dependency or first-party result

### Requirement: SQLite test resources close before filesystem cleanup
Every test that creates a SQLite-backed Jort store SHALL retain ownership of that store, close all live connections before removing its temporary directory, and report cleanup failures without replacing the test's primary failure.

#### Scenario: SQLite-backed test finishes normally
- **WHEN** a test completes after opening one or more document, settings, history, or composite package stores
- **THEN** it closes every owned store in dependency order before deleting the temporary directory
- **AND** the test run emits no warning that a SQLite vnode was unlinked while in use

#### Scenario: Test assertion or store operation fails
- **WHEN** a test exits through a thrown error or failed assertion after opening a store
- **THEN** teardown still attempts to close every retained connection before directory removal
- **AND** cleanup diagnostics preserve rather than replace the primary test failure

### Requirement: Engineering checks have explicit enforcement roles
Jort SHALL document the local and CI commands for formatting, project generation, tests, analysis, sanitizers, packaging, and performance, including whether each result is blocking, informational, or conditionally enforced.

#### Scenario: Known performance failure exists during this change
- **WHEN** the engineering-baseline checks encounter the previously documented native performance-budget failure
- **THEN** they report it with its existing enforcement mode and owning follow-up change
- **AND** this change does not silently raise the budget or disable CI enforcement to produce a passing result

#### Scenario: Contributor selects a verification command
- **WHEN** a contributor consults the repository verification documentation
- **THEN** they can determine which command exercises each quality gate and whether failure blocks completion
- **AND** informational dependency audits are distinguishable from blocking first-party checks
