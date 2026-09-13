# Model-backed tool verification

Implementation verification, September 13, 2026. The change is not yet release-qualified; unchecked tasks remain explicit in `tasks.md`.

## Automated evidence

- Foundation: 122 tests passed, zero failures. Covers legacy and model package contracts, Settings schema migration, registry conflicts, unavailable model preservation, definition round trips, provider request shape, malformed/oversized output, cancellation, OAuth correlation and replay, local callback success/cancellation/expiration, credential replacement rollback, Keychain fault injection, and secret isolation.
- Native: 101 tests passed, zero failures. Covers the existing foundation editor interactions, Settings, history/search, IME boundary checks, every input mode with a fake model, unrelated editing during execution, captured configuration after Settings changes, Merge/Dismiss/Undo/Redo, disconnected warnings, authentication failures, and pending/in-flight relaunch without another request.
- Strict OpenSpec validation and `git diff --check` passed.
- Real-app UI: the runner could not initialize, first because of system authentication and then because enabling automation mode timed out after unlock. No real-app UI tests ran. The user explicitly requested skipping inaccessible checks; no further harness or accessibility setup is required for this change.

## Authority and privacy audit

`ModelRequest` contains only request identity, tool identity/version, selected model, instructions, exact captured content, and numeric limits. It holds no document, editor, settings, history, filesystem, process, JavaScript, or application reference. The OpenRouter JSON body includes only model, messages, output-token limit, and `stream: false`. No tool-call declarations are sent. Unsupported tool calls, streaming fragments, multiple choices, malformed output, and truncated completion are rejected.

The native transport accepts only three fixed HTTPS paths on `openrouter.ai`, rejects redirects, uses an ephemeral session without cookies or cache, limits transport bytes, and applies request/resource timeouts. The provider reads credentials only during execution. Opening Settings, catalog filtering, ordinary editing, search/history, and JavaScript tools do not create a URLSession or start OAuth. Model execution is never retried automatically.

Credentials are stored in a nonsynchronizing app-scoped Keychain item. OAuth codes/verifiers stay in the attempt's memory. Status persistence stores enum categories and dates only; even server-provided labels are excluded to prevent reflected secrets. Connect verifies a replacement before updating Keychain. Local disconnect does not revoke remote keys and explains account management.

## Measurements

Debug measurements on this Mac. Nearest-rank p95; these characterize behavior and are not a release performance approval.

| Operation | p95 |
| --- | ---: |
| Filter bundled models | 0.005 ms |
| Validate/capture model request | 0.005 ms |
| Dispatch through deterministic fake | 0.069 ms |
| Submit from 1-million-UTF-16-unit document | 0.238 ms |
| Delayed fake submission through canonical publication | 696.55 ms |
| Cancel in the large document | 181.75 ms |

The large-document fixture has approximately 25,000 lines. Publication and cancellation include the existing snapshot, annotation, layout, and persistence work and remain above the ordinary editor's 100 ms regression target. The previous JavaScript large-document measurements also exceed that target (`docs/tool-verification.md`). This change does not claim to solve that existing scaling issue.

## Remaining qualification

- Tasks 8.4 (real-app portion) and 8.5 (live OAuth/VoiceOver qualification) were skipped at the user’s explicit request. They remain unchecked to distinguish skipped checks from verified results. All other automated portions of 8.4 passed.
- Local/fake tests do not establish live-provider or physical assistive-technology qualification. These checks can be performed later before release; they do not block the user-accepted implementation handoff.
