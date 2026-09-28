## Why

Jort's validation is comprehensive, but Codex frequently bypasses its canonical wrapper for targeted builds and tests, producing repeated approval prompts and excessive model-visible output. The repository also lacks durable guidance and model-specific agent roles for assigning deterministic work to scripts and reserving expensive reasoning for genuinely difficult engineering.

## What Changes

- Expand the canonical validation dispatcher to support focused Foundation/native tests, Debug/Release configuration, changed-file planning, compact failure extraction, and serialized Xcode execution.
- Keep every requested validation fresh: do not cache passing test results or infer success from an earlier run.
- Add a concise repository `AGENTS.md` and a repo skill that require the canonical dispatcher, bounded output, focused-first/final-once validation, and deliberate subagent routing.
- Add project-local Codex configuration, narrow model-specific agent roles, and approval rules for the enumerated validation interface.
- Preserve existing CI lane names and behavior while routing their execution through the same command surface.
- Do not add developer-experience telemetry or usage tracking.

## Capabilities

### New Capabilities

- `ai-native-development-workflow`: Defines Jort's stable validation interface, output bounds, fresh-execution policy, approval surface, and model-routing guidance.

### Modified Capabilities

None.

## Impact

The change affects `scripts/validate`, validation helpers, root repository guidance, repo-local Codex configuration/rules/agents, a Jort development skill, and validation documentation. It introduces no application runtime behavior, persisted-data changes, or external dependencies.
