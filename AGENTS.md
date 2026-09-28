# Jort agent instructions

Use `./scripts/validate` for builds and tests. Do not invoke `xcodebuild`, XCTest,
or the underlying test scripts directly during normal development. Start with
`./scripts/validate changed --plan-only`, run a focused check while iterating, and
run `./scripts/validate gate` once after the final code change. Each request runs
fresh; prior summaries are diagnostic records, never proof that current code passes.

Keep command output bounded. Read `summary.json` or use `./scripts/validate result`
before opening a full log, and quote only the relevant failure excerpt. Do not rerun
a passing full lane merely for reassurance when no input changed.

Apply the repo-local `jort-development` skill for implementation work. Delegate
read-only discovery and log triage to the inexpensive explorer or test-triage agent,
routine isolated edits to the implementer, hard cross-module debugging to the
hard-problem agent, and final review to the reviewer. Keep coordination and final
integration in the main task.
