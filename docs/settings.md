# Settings and tool configuration

Jort has one modeless native Settings window, opened from **Jort → Settings**, Command-comma, or **Open Settings** in Pocket. Registered panes appear in a source-list sidebar; the selected pane and window frame are remembered without becoming document state.

Application settings live under the active data root at `Settings/Settings.sqlite`. This database has its own schema and lifecycle. Changing a setting does not create document Undo, autosave, recovery, or version-history entries. A missing database is created with defaults. Corrupt and future-version databases are preserved unchanged and reported in Settings; they never block access to the document.

## Tool ownership

Bundled tools are immutable versioned templates. They can be enabled, disabled, inspected, or duplicated. **Duplicate to Customize** creates a separate user-owned definition, so an application update cannot overwrite edited source. Custom tools can be created, edited, disabled, and explicitly deleted after confirmation.

Tool names, slash commands, descriptions, record counts, and UTF-8 JavaScript source are bounded before persistence. Slash commands use 1–64 lowercase ASCII letters, digits, or hyphens and begin with a letter. Source is limited to 256 KiB. Command names remain unique across templates and custom definitions.

The source field is a native plain-text editor with monospaced text, line numbers, Find, local Undo/Redo, exact UTF-8 round trips, and diagnostics. Smart quotes, smart dashes, attachments, spelling correction, and automatic substitutions are disabled.

## Execution boundary

Settings stores definitions and publishes immutable revisions containing committed, enabled, valid, non-conflicting tools. It does not execute or preview JavaScript, instantiate a JavaScript engine, grant permissions, access the network or shell, or launch processes. `build-jort-run-tools` must later consume this read-only catalog and independently define its JavaScript runtime, sandbox, authority, and invocation behavior.

## Models and model-backed tools

Tools Settings offers JavaScript and Model executors. Model tools use a plain-text instructions editor and a local filterable model picker; authoring and Save work while disconnected. Changing executor requires confirmation before discarding implementation content. Removed catalog selections are retained with an unavailable diagnostic.

Models Settings connects to OpenRouter through the system browser using PKCE S256. The temporary callback binds only to IPv4 loopback on an OS-selected port, uses a random route for attempt correlation, expires after three minutes, and accepts a single bounded authorization code. OpenRouter supports localhost callbacks on arbitrary ports. The localhost host/port is the authorization app label; Jort does not use a public redirect relay.

The issued credential is verified before an atomic nonsynchronizing Keychain replacement. A failed or cancelled replacement keeps the prior credential. Check Connection is explicit; opening Settings does not issue a request. Disconnect removes the local credential and explains how to revoke it remotely through OpenRouter account management. No API-key input, reveal, clipboard import, or export is provided. Persisted status contains only a state category and dates, never server-provided strings that might reflect a secret.

API references verified September 13, 2026:
- [OpenRouter OAuth PKCE](https://openrouter.ai/docs/guides/overview/auth/oauth)
- [GPT-5.4 Mini](https://openrouter.ai/openai/gpt-5.4-mini)
- [GPT-5.4 and Claude Sonnet 4.6](https://openrouter.ai/compare/openai/gpt-5.4/anthropic/claude-sonnet-4.6)
