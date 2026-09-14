## Why

Tool configuration, package persistence, JavaScript execution, model-provider behavior, and invocation state currently cross the `JortSettings` and AppKit boundaries. That coupling makes domain behavior require native UI infrastructure and would turn the later QuickJS process boundary into a copy of today's dependency problems unless contracts and lifecycle ownership are extracted first.

## What Changes

- Add compiler-enforced modules for bounded tool contracts and runtime/provider execution, with no AppKit dependencies.
- Reduce `JortSettings` to preferences, configuration persistence, package storage, catalog publication, and credential configuration interfaces; it no longer imports or initializes QuickJS.
- Move the authoritative invocation lifecycle into a pure, `Sendable` reducer/coordinator outside AppKit.
- Make AppKit translate native selection, range, focus, and user events into reducer actions and render reducer state without owning lifecycle transitions.
- Define an acyclic ownership boundary for persisted invocation metadata between `JortDocument` and the new contract module.
- Move lifecycle and execution-dispatch tests to headless targets while retaining AppKit tests for text-system, geometry, focus, accessibility, and end-to-end integration.
- Preserve package formats, command behavior, canonical mutations, provider behavior, failure semantics, and user-visible invocation behavior during the extraction.

## Capabilities

### New Capabilities
- `tool-execution-architecture`: Defines module responsibilities and dependency direction, bounded execution contracts, pure invocation state ownership, composition boundaries, and headless verification.

### Modified Capabilities
- `deterministic-builtins`: Requires JavaScript package validation and execution to be reached through the runtime abstraction rather than owned by Settings.
- `inline-command-invocation`: Makes the non-AppKit reducer/coordinator authoritative for invocation lifecycle transitions while AppKit remains a native event and presentation adapter.
- `asynchronous-agent-runs`: Places lazy model-provider construction and bounded model execution behind the shared runtime boundary and lifecycle contracts.

## Impact

- Adds `JortToolContracts` and `JortToolRuntime` targets and updates dependency declarations and generated-project checks in `project.yml`.
- Moves or replaces tool/package contract types currently in `Sources/JortSettings`, runtime and provider code currently coupled to Settings, and lifecycle logic currently in `Sources/JortAppKit/ToolInvocationController.swift`.
- Reconciles persisted invocation value ownership in `Sources/JortDocument/ToolInvocation.swift` without changing the on-disk representation.
- Splits the large AppKit invocation suite so reducer, contract, runtime-dispatch, and provider behavior can run without `NSApplication`, `NSWindow`, or `NSTextView`.
- Establishes the contract seam consumed by the later `sandbox-javascript-execution` change; this change does not add XPC or alter the security boundary itself.
