# Change: Build Jort V1

## Why

Jort needs to turn the validated product direction and interaction prototype into a native macOS application without losing the simplicity that makes the concept valuable. The product must open as an immediately editable, local plain-text canvas while keeping landmarks, history, AI, scripting, commands, and external capture optional and visibly bounded.

The current web prototype demonstrates the intended interaction hierarchy, but it does not validate native text editing, paragraph anchoring, persistence, permissions, launch performance, or safe background mutation. A native foundation is required before provider, scripting, and capture integrations can be trusted.

## What Changes

- Create a native Swift/SwiftUI macOS app named Jort with one canonical app-owned plain-text document.
- Implement the editor with `NSTextView` and TextKit 2, including a narrow logical-line gutter and native editing behavior.
- Persist the current document, logical-line metadata, annotations, landmarks, full-state revisions, runs, inbox items, and settings in SQLite/WAL without blocking keystrokes.
- Add paragraph-anchored emoji landmarks and a gutter mode that replaces line numbers with a compact, top-aligned landmark table of contents.
- Add local version history with atomic preview and restore of text plus metadata.
- Add inline `@agent` and `/command` invocation decoration at the actual invocation line, visible context selection, and explicit Shift+Enter execution.
- Insert completed output atomically as ordinary text immediately after the invocation, retaining removable provenance metadata rather than a chat transcript.
- Enforce a capability-and-consent model for document, history, network, mutation, and registered-command access.
- Support lazy local and OpenAI-compatible cloud model providers behind a small common contract.
- Add JavaScriptCore scripts, built-in commands, and separately registered external commands with narrow inputs, limits, and no ambient shell authority.
- Add optional webhook/Pebble capture through a relay inbox, emoji-landmark routing, and a notification queue that never silently reroutes missing destinations.
- Preserve launch, focus, typing latency, viewport stability, and failure-isolation invariants throughout.

## Capabilities

### New Capabilities

- `editor-canvas`: Native one-document editor, logical-line model, annotations, invocation decoration, permissions, and performance invariants.
- `landmarks`: Emoji landmark anchoring, line-number replacement, landmark navigation mode, and routing identity.
- `persistence-history`: Asynchronous local persistence, timestamp metadata, revision creation, history preview, and atomic restore.
- `automation-runtime`: Agents, providers, inline execution lifecycle, JavaScriptCore scripts, built-ins, and registered external commands.
- `external-capture`: Webhook/Pebble inbox, connection routing, notifications, missing-destination queue, and acknowledgements.

### Modified Capabilities

- None. This is the first formal product specification for Jort.

## Impact

- Introduces a new native macOS application target and supporting modules for editor, storage, automation, providers, commands, and capture.
- Treats the existing React prototype as a disposable interaction reference, not production architecture.
- Requires SQLite schema design, TextKit anchoring prototypes, a JavaScriptCore bridge, provider clients, and a minimal authenticated relay API.
- Defers Mac App Store distribution until external-command and sandbox prototypes establish the viable authority model.

## Non-goals

- Multiple notes, files, folders, notebooks, tabs, or a document library.
- Rich-text authoring or block-based document semantics.
- An assistant conversation, streaming tokens into the editor, or a persistent chat transcript.
- Permanent AI access to the whole document or version history.
- Bundling Node.js or exposing arbitrary shell, filesystem, or network access to scripts.
- Requiring an account, model provider, network connection, capture service, or plugin for launch and typing.
