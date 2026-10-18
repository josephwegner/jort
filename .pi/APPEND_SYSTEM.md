# Jort pi workflow

AGENTS.md and .agents/skills/ are shared with other coding agents; use them directly.

For delegation, use the subagent tool with agentScope: "project":
- explorer: bounded read-only discovery (Luna, low thinking).
- test-triage: inspect a supplied validation summary/log (Luna, low).
- implementer: routine isolated edits (Terra, medium).
- hard-problem: ambiguous cross-module debugging (Astra, high).
- reviewer: final read-only review (Terra, high). Supply the scoped diff or a
  temporary diff file and validation results, since this agent has no shell.

Batch independent work in one tasks call (at most four children run at once).
Do not dispatch overlapping write tasks. Keep coordination, final integration,
and the final ./scripts/validate gate in the main session. Children must not
recursively delegate. If subagent is unavailable, explain the limitation and
perform the work in the main session rather than claiming delegation happened.

Use ./scripts/validate for routine builds/tests and result inspection. The Codex
validation prefix approval rule has no built-in pi equivalent: this is workflow
guidance, not a sandbox or shell permission boundary. Do not invoke xcodebuild,
XCTest, or underlying build/test scripts directly during normal development.
