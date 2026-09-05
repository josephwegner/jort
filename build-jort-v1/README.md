# Jort Product Roadmap Source

This directory preserves the original `build-jort-v1` OpenSpec change as product and architecture source material. It is not an active, implementation-ready OpenSpec change and should not be applied directly.

The product is expected to progress through separately proposed changes:

1. **Crawl MVP:** a native one-document text editor with excellent editing behavior, autosave, crash recovery, and only the minimal logical-line metadata needed by later phases.
2. **Walk MVP:** emoji landmarks and the command palette.
3. **Run MVP:** simple agents and tools, local history, and search.
4. **V1:** connectors, decorated insertions, developer experience for tools and agents, and notifications.

## Decisions that supersede these artifacts

- The interaction specification remains authoritative where the React POC contains visual bugs or hard-coded test state. In particular, an invocation decorates its actual canonical-text line, and visible context labels must match the exact submitted ranges.
- The Crawl MVP accepts a crash-loss window of up to one second.
- When persistence fails, editing continues in memory. Jort shows a nonmodal notification, retries automatically a small number of times, and then offers manual retry.
- When the SQLite store is corrupt, Jort preserves a backup of the damaged store and recovers the newest safe state when possible rather than silently overwriting it.
- The Crawl MVP includes only the editor, autosave/recovery, and minimal logical-line metadata. Landmarks, palette, history, search, automation, providers, capture, and extensibility belong to later changes.
- A successfully completed insertion does not retain state solely to support Retry. Editing changes the insertion; Merge removes its decoration and association. Failed, timed-out, or interrupted runs may offer manual retry from their persisted operational record, but Jort never retries them automatically after relaunch.
- The generic plain-text export feature is removed. Format-specific output can be provided by later tools such as `/pdf`.
- Provider locality does not need a dedicated Local/Cloud badge in the initial automation UX, although AI invocations must remain distinguishable from deterministic tools and commands.
- All configuration and extension actors are the same local power user/note-taker.
- External capture remains deferred. The initial payload direction is text-only, at most 250 characters, with a caller-supplied request identifier for deduplication.
- Accessibility behavior for custom editor, gutter, palette, automation, history, notification, and configuration surfaces must be expressed as normative requirements in their respective phase changes.

## Recommended next action

Create a fresh OpenSpec proposal for the Crawl MVP rather than narrowing or applying the archived umbrella artifacts.
