## Context

Jort already has a concise validation orchestrator, but its static lanes cannot express filtered tests, alternate build configurations, or change-aware planning. Agents therefore invoke `xcodebuild` directly with subtly different command lines, causing repeated approvals and exposing large logs. The repository also has no root agent guidance or checked-in custom-agent configuration.

The workflow is used primarily by Codex Desktop on macOS. Standard checks need Xcode access outside the workspace sandbox, so a small stable executable surface is necessary for reusable approval rules. Full logs must remain available for diagnosis without entering the coordinator context.

## Goals / Non-Goals

**Goals:**

- Make `./scripts/validate` the complete normal interface for focused and final validation.
- Execute every requested check freshly while avoiding accidental duplicate full-suite runs through workflow guidance.
- Emit concise summaries and retain complete logs and result bundles on disk.
- Select useful checks from changed paths using transparent deterministic rules.
- Serialize Xcode-backed lanes that contend for shared macOS resources.
- Provide safe project-local approval rules and narrow, model-specific agent roles.
- Keep expensive models focused on difficult design, implementation, debugging, and review.

**Non-Goals:**

- Caching passing tests or skipping a requested validation based on an earlier result.
- Measuring approvals, token usage, model usage, or developer-experience metrics.
- Automatically changing the main chat model during a turn.
- Replacing CI, XCTest, Xcode, OpenSpec, or existing validation coverage.

## Decisions

### One validation dispatcher with explicit subcommands

Retain existing lane invocations for compatibility and add `focused`, `changed`, `gate`, and `result` modes. `focused` accepts only enumerated suites/configurations and repeated XCTest identifiers; it never accepts arbitrary commands. `changed` reports its file-to-check mapping and executes the selected checks. `gate` is the canonical final validation set. `result` reads a stored summary or failure excerpt without rerunning tests.

This is preferred over adding more shell scripts because one stable prefix is easier to approve, document, validate, and keep output-safe.

### Fresh execution without evidence caching

Every validation request runs. Stored summaries are diagnostic artifacts only and never authorize skipping work. Repository guidance says to run focused checks during iteration and the full final gate once after the implementation stabilizes; discipline replaces caching.

### Compact output backed by complete local artifacts

Each command writes stdout/stderr to a run directory. Success prints one row per check. Failure extraction prefers structured XCTest result data when available and falls back to bounded diagnostic matching. The dispatcher never prints a complete build log. `summary.json`, logs, and `.xcresult` paths remain available for targeted follow-up.

### Deterministic changed-file planning

A checked mapping assigns repository path prefixes to validation checks and focused XCTest suites. The plan is printed before execution. Unknown production/test paths conservatively select the main test lane. Documentation-only changes choose lightweight checks. This planner is advisory in breadth but fresh in execution.

### Serialized Xcode ownership

The dispatcher uses one repository-local file lock for Xcode-backed checks. This prevents native, UI, analysis, and build lanes from competing for shared DerivedData, test runners, or app focus. Non-Xcode checks may remain sequential initially; correctness and predictable output matter more than orchestration complexity.

### Checked-in Codex policy layers

A short root `AGENTS.md` defines durable workflow rules. A repo skill holds detailed validation and delegation procedures. Project-local `.codex/config.toml`, agent definitions, and execution rules configure Luna for bounded exploration/log triage, Terra for routine implementation/review, and Astra for difficult cross-cutting work. Agent roles have the narrowest practical sandbox.

The main model is not switched automatically. Applicable repository guidance requests subagent delegation so Codex Desktop can route bounded tasks through model-specific agents.

## Risks / Trade-offs

- **Changed-file mapping misses a dependency** → Unknown or shared infrastructure paths conservatively select broader checks; the final gate remains mandatory.
- **Exact approval prefix becomes too powerful** → The dispatcher exposes enumerated arguments only, rejects passthrough commands and arbitrary paths, and the rule includes match/non-match examples.
- **Compact excerpts hide a useful clue** → The failure always reports the complete log/result path and `result` can retrieve a bounded larger excerpt without rerunning.
- **Model-specific names are unavailable on another host** → Custom agents are explicit repository configuration and can be adjusted independently; deterministic tooling remains usable without subagents.
- **Xcode serialization increases wall time** → It avoids flaky GUI/test-runner contention and duplicate builds; focused checks retain fast iteration.

## Migration Plan

Keep all existing validation lanes working. Add and self-test the new modes, then update README/guardrails and CI documentation. Check in project policy files by narrowing the existing `.codex` ignore rule. Validate execution-policy matches, Python behavior, representative focused/changed runs, and the canonical final gate. Rollback consists of removing the repo policy files and reverting the dispatcher extensions; application code and persisted data are unaffected.

## Open Questions

None. Model availability and account-specific usage accounting remain external configuration concerns rather than workflow correctness requirements.
