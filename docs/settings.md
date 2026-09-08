# Settings and tool configuration

Jort has one modeless native Settings window, opened from **Jort → Settings**, Command-comma, or **Open Settings** in Pocket. Registered panes appear in a source-list sidebar; the selected pane and window frame are remembered without becoming document state.

Application settings live under the active data root at `Settings/Settings.sqlite`. This database has its own schema and lifecycle. Changing a setting does not create document Undo, autosave, recovery, or version-history entries. A missing database is created with defaults. Corrupt and future-version databases are preserved unchanged and reported in Settings; they never block access to the document.

## Tool ownership

Bundled tools are immutable versioned templates. They can be enabled, disabled, inspected, or duplicated. **Duplicate to Customize** creates a separate user-owned definition, so an application update cannot overwrite edited source. Custom tools can be created, edited, disabled, and explicitly deleted after confirmation.

Tool names, slash commands, descriptions, record counts, and UTF-8 JavaScript source are bounded before persistence. Slash commands use 1–64 lowercase ASCII letters, digits, or hyphens and begin with a letter. Source is limited to 256 KiB. Command names remain unique across templates and custom definitions.

The source field is a native plain-text editor with monospaced text, line numbers, Find, local Undo/Redo, exact UTF-8 round trips, and diagnostics. Smart quotes, smart dashes, attachments, spelling correction, and automatic substitutions are disabled.

## Execution boundary

Settings stores definitions and publishes immutable revisions containing committed, enabled, valid, non-conflicting tools. It does not execute or preview JavaScript, instantiate a JavaScript engine, grant permissions, access the network or shell, or launch processes. `build-jort-run-tools` must later consume this read-only catalog and independently define its JavaScript runtime, sandbox, authority, and invocation behavior.
