# Jort in pi

Start `pi` from the repository root, approve the project resources, and use
`/reload` after configuration changes (or restart pi). No npm installation or
changes to global pi settings are required. This setup was ported from
`.codex/config.toml`, `.codex/agents/*.toml`, and
`.codex/rules/jort-validation.rules` using pi 1.3.0.

## Shared instructions and skills

Pi already reads the root `AGENTS.md` and discovers `.agents/skills/`, including
`jort-development` and the twelve OpenSpec skills. The corresponding
`.codex/skills/` copies were identical at migration time, so no second pi copy
was made. Use `/skill:jort-development` or `/skill:openspec-apply-change` directly.

The twelve `.pi/prompts/opsx-*.md` templates also provide convenient commands:
`/opsx-new`, `/opsx-propose`, `/opsx-explore`, `/opsx-continue`, `/opsx-ff`,
`/opsx-update`, `/opsx-apply`, `/opsx-verify`, `/opsx-sync`, `/opsx-archive`,
`/opsx-bulk-archive`, and `/opsx-onboard`. Arguments are passed to the shared skill.

## Specialized agents

Pi does not ship a built-in subagent tool. `extensions/subagent/` vendors the
bundled pi 1.3.0 subagent example (`index.ts` and `agents.ts`), under pi's MIT
license, rather than depending on an absolute path into one person's install.
Upstream: https://github.com/earendil-works/pi/tree/main/packages/coding-agent/examples/extensions/subagent

Local change: child processes disable extensions and MCP, preventing recursive
delegation and extension-provided tools. Review upstream changes before updating.
The vendored example retains upstream edge cases: malformed YAML can interrupt
agent discovery, and an externally signal-killed child may be reported as successful.
Treat empty child output as inconclusive and inspect failures rather than using a
child's completion status as proof of validation.

`.pi/agents/*.md` ports the Codex roles and preserves model/reasoning choices:

| Role | Model | Thinking | Tools |
| --- | --- | --- | --- |
| explorer | openai/gpt-5.6-luna | low | read, grep, find, ls |
| test-triage | openai/gpt-5.6-luna | low | read, grep, find, ls |
| implementer | openai/gpt-5.6-terra | medium | read, bash, edit, write |
| hard-problem | openai/gpt-6-astra | high | read, bash, edit, write |
| reviewer | openai/gpt-5.6-terra | high | read, grep, find, ls |

These model IDs were present in this installation's authenticated model list.
Use `/login` for OpenAI if needed. Edit each agent's `model` field to change its
provider/model and `:thinking` suffix. The main session keeps your personal model
default; the Codex project configuration did not specify a coordinator model.

Ask pi to delegate naturally, e.g. “Use explorer to locate the overlay code.”
`APPEND_SYSTEM.md` instructs it to select project agents. The tool equivalent is:

```json
{"agent":"explorer","task":"Locate the overlay presentation entry points.","agentScope":"project"}
```

The upstream tool supports single, parallel (`tasks`), and sequential (`chain`)
runs, with four workers per parallel invocation and up to eight queued tasks.
Unlike Codex's session-wide limit, this is a per-invocation limit: batch work in
one call and do not launch simultaneous batches. Children share the working tree;
assign non-overlapping edits. They use isolated contexts, so supply the relevant
paths, constraints, and results. Supply reviewer a scoped diff file since it has
no shell tool.

## Permissions are not equivalent

Codex's validation prefix approval rule has no built-in pi settings equivalent.
`AGENTS.md` and `APPEND_SYSTEM.md` preserve the `./scripts/validate` workflow as
instructions, not an enforced shell allowlist. Pi normally does not prompt for
each tool call.

Read-only roles expose only file-reading/search tools, not bash/edit/write.
This reduces their available actions but is **not** Codex's OS-level read-only
sandbox. Write roles run with the current user's permissions, not a
workspace-write sandbox. Use OS isolation if you need an actual security boundary.
Project trust approves executable project resources, not individual shell commands.

The existing Codex configuration, shared skills, app code, credentials, and global
agent configuration are intentionally unchanged.
