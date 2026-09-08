## Why

Jort needs a durable home for product configuration before third-party tools introduce enablement, editable definitions, and JavaScript source. A native, extensible Settings workspace now prevents tool configuration from becoming one-off editor chrome and establishes patterns that later preferences can reuse.

## What Changes

- Add a single-instance native Settings window opened from the Jort menu, Command-comma, or Pocket, with a scalable sidebar-and-detail structure and remembered navigation state.
- Add a pane registration boundary so future settings areas can be composed without centralizing their views, state, validation, and persistence in the application delegate.
- Add a versioned, observable application-preferences store that is separate from canonical document content, document undo/history, and document recovery.
- Add an initial Tools pane that lists built-in templates and user-defined tools, supports enable/disable, and lets users duplicate a template or create, edit, and remove a custom tool.
- Add a lightweight bounded JavaScript source editor with native text behavior, dirty/validation state, explicit save or discard, and accessible diagnostics.
- Define the handoff between Settings and the future tool catalog/runtime while keeping JavaScript execution, sandboxing, tool invocation, and permission grants out of this change.

## Capabilities

### New Capabilities

- `settings-workspace`: Native Settings window lifecycle, pane navigation, focus, sizing, extensibility, and accessibility behavior.
- `application-preferences`: Versioned non-document preference storage, validation, observation, atomic persistence, recovery, and forward-compatibility behavior.
- `tool-configuration`: Built-in template and custom-tool management, enablement, JavaScript draft editing, validation presentation, and the configuration boundary consumed by a later tool runtime.

### Modified Capabilities

- `command-palette`: Pocket exposes an Open Settings action that routes to the same single-instance Settings window as the application menu and keyboard shortcut.

## Impact

- Adds Settings window composition and pane infrastructure to `JortAppKit`, with application-level lifecycle/menu wiring in `Jort`.
- Adds preference and tool-definition models plus a versioned local settings store outside the document snapshot and SQLite history schema.
- Introduces a narrow tool-catalog adapter that `build-jort-run-tools` can implement without coupling its execution engine to Settings UI.
- Adds native AppKit controls and text editing only; no web view, package-based code editor, JavaScript engine, network access, shell access, or external process is introduced.
- Requires coordination with `build-jort-run-tools`: its current deterministic built-in registry remains the execution source of truth until the later JavaScript runtime adopts the configuration contract.
