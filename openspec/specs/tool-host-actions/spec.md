# tool-host-actions Specification

## Purpose

Define the bounded typed host-action contract for Jort tool packages, including validation, dispatch, recovery, and supported clipboard, export, notification, and landmark actions.

## Requirements

### Requirement: Typed results separate text reports and host actions
Contract 2 SHALL return exactly one bounded text result, report, typed host-action request, or error. The action allowlist SHALL be rich clipboard copy, file export, and notification scheduling. A text result MAY carry one validated landmark attachment to its own output. Host services SHALL be injected at app composition and SHALL execute only after explicit submission, package/action/content validation, and generation checks; manifest declarations alone SHALL NOT authorize execution.

#### Scenario: Custom tool requests an allowed action
- **WHEN** an enabled custom package declares an action and its submitted result satisfies the same policy used for bundled tools
- **THEN** the app validates and dispatches that action through its typed adapter
- **AND** no filesystem path, credential, native object, generic HTTP request capability, or callback is exposed to JavaScript

#### Scenario: Invalid or stale action arrives
- **WHEN** a result mixes text and action, requests an undeclared action, exceeds bounds, or names an obsolete generation
- **THEN** the host rejects it before any side effect
- **AND** discovery, validation, model output, and rendering never execute host actions

### Requirement: Action completion does not imply replay or reversal
Jort SHALL dispatch at most once per live generation, acknowledge actual outcomes, and retain bounded recovery receipts where required. Reopening, Undo/Redo, Dismiss, Done, or restoring an invocation SHALL NOT replay an action. Interrupted or unacknowledged action results SHALL remain unknown without automatic retry. Source content SHALL be preserved.

#### Scenario: Cancellation races an external effect
- **WHEN** cancellation occurs before dispatch
- **THEN** no action occurs
- **AND** when cancellation occurs after dispatch, feedback distinguishes confirmed completion from unknown outcome without claiming reversal

#### Scenario: Application exits before action acknowledgement
- **WHEN** no definitive action receipt was recorded before exit
- **THEN** restored feedback states the outcome is unknown and performs no automatic action replay
- **AND** explicit retry uses a new generation

### Requirement: Rich copy publishes interoperable clipboard representations
`/copy-rich` SHALL render Markdown to bounded rich and readable plain-text clipboard representations, including RTF/HTML, before publishing them together. It SHALL support headings, emphasis, lists, links, quotes, and code with readable fallbacks, and SHALL neither execute raw HTML nor fetch remote resources.

#### Scenario: Rich and plain targets paste
- **WHEN** the user copies a Markdown block and pastes into a compatible rich-text target and a plain-text target
- **THEN** the first receives supported formatting and the second readable text
- **AND** the original block remains unchanged

### Requirement: Export writes only to a user-selected destination
`/export` SHALL open a native save panel, suggest a sanitized heading-derived filename or `note.md`, and write exact UTF-8 captured content as Markdown or plain text. Overwrites SHALL use native confirmation. Completion SHALL be reported only after a successful write.

#### Scenario: Save is cancelled or fails
- **WHEN** the panel is cancelled or the selected file cannot be written
- **THEN** no successful export is reported and the source/invocation remain available
- **AND** scripts cannot supply an arbitrary destination path

### Requirement: Reminder scheduling is durable and acknowledged
`/remind` SHALL require integer minutes 1–525600, capture content at submission, and schedule an OS notification for submission time plus that delay. It SHALL request notification permission when needed, acknowledge OS acceptance rather than elapsed JavaScript time, and retain bounded private reminder details and a cancellation identifier. Notification delivery SHALL respect OS notification settings, and feedback SHALL not promise exact delivery timing.

#### Scenario: Jort exits before a reminder is due
- **WHEN** an accepted reminder becomes due after Jort exits
- **THEN** delivery uses the OS schedule without requiring a live JavaScript worker
- **AND** activation opens Jort with captured reminder text even if the original block changed

#### Scenario: Permission or scheduling fails
- **WHEN** notification permission is denied or the OS rejects scheduling
- **THEN** Jort reports the actionable failure without claiming a reminder exists
- **AND** content remains available

#### Scenario: Reminder is long or cancelled
- **WHEN** captured text exceeds the notification preview length
- **THEN** the visible preview truncates at a grapheme boundary and full bounded text remains available in reminder detail
- **AND** pending reminders can be cancelled from completion feedback; delivered or expired receipts are cleaned up under a bounded retention policy

### Requirement: Daily inserts a real landmark atomically with its header
`/daily` SHALL expose editable JavaScript date format, header template, and emoji defaults. It SHALL preview a dated heading and two trailing newlines, then create a metadata-only calendar emoji landmark attached to that heading's stable LineID during Merge. Each explicit invocation SHALL create a new daily entry without whole-document duplicate detection.

#### Scenario: Daily output is merged and undone
- **WHEN** the user merges `/daily` output
- **THEN** header insertion and landmark attachment occur in one document transaction
- **AND** Undo/Redo restores both text and landmark identity/attachment together

#### Scenario: Daily output is dismissed
- **WHEN** the pending daily result is dismissed or its anchor becomes invalid
- **THEN** no permanent landmark remains
- **AND** ordinary source/output recovery rules preserve document integrity
