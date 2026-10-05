## Context

Jort is one continuous document. Its existing contextual tool input is an adjustable, contiguous range initially covering the command's logical line, excluding the command token. It is not an inferred paragraph, selection, separate note, or whole document. Preserve that model throughout this change.

`Jort/Resources/Tools` currently bundles date, time, uuid, calc, sort, dedupe, ask, and rewrite. JavaScript receives only content, captured UTC clock, UUID, and cancellation state. QuickJS has neither Date nor random nor I/O bindings; it executes in a disposable sandboxed worker. Results currently contain only output or error. Canonical output is published pending explicit Merge, with Dismiss and Undo. Model packages already use a configured OpenRouter connection.

Clipboard, export, reminders, presentation-only counts, separate context arguments, and metadata landmarks therefore require shared contract work as well as scripts. These examples must remain editable and reusable by custom packages.

## Goals / Non-Goals

Goals: deliver the full agreed catalog, specific completion descriptions, editable scripts/prompts, predictable scope and arguments, explicit native action behavior, and compatibility with user overrides and historical invocations.

The bundled implementations are teaching examples: use descriptive names, small functions, clearly marked customization constants, and comments that explain non-obvious choices. Keep each script self-contained and readable; avoid compressed code or hidden command-dispatch helpers that obscure how to build a new tool.

Non-goals: multiple documents, note linking, general filesystem/network/shell access, an arbitrary plugin bridge, Reminders-app task integration, new AI providers, or a rendered Markdown navigation system. `/remind` schedules notifications, not Apple Reminders tasks. `/toc` produces portable Markdown links; it does not promise navigation inside Jort.

## Decisions

### 1. Catalog and exact behavior

The catalog below includes the 15 remaining selected tools plus the subsequent additions, including unescape, JSON minification, simplify, and concise. `/copy-rich` appears once. Long count names remain as explicitly requested; additional aliases are unnecessary.

Modes: **generate** uses contained input and replaces the invocation after Merge; **transform** uses contextual content and replaces that context after Merge; **insert** uses contextual content but inserts output at the invocation after Merge; **report/action** preserves content and completes through presentation-only feedback. Generator arguments occupy the owned contained input; they are never copied into generated output. Zero-argument generators reject non-whitespace arguments. Argument examples describe accepted invocations, not automatic execution.

| Command | Readable description and behavior | Mode |
| --- | --- | --- |
| `/now` | Insert local date and time: `Sept 12, 10:28am`. | generate |
| `/today` | Insert local weekday and date: `Sat, Sept 12`. | generate |
| `/time` | Insert local time: `10:28am`. | generate |
| `/copy-rich` | Copy Markdown as rich text, with HTML/RTF and readable plain-text clipboard representations. | action |
| `/export` | Save the exact content block as UTF-8 Markdown; offer plain text as another extension, without Markdown stripping. Native save panel selects name/destination. | action |
| `/lorem [N]` | Insert N standard lorem ipsum paragraphs separated by blank lines; default 1, integer range 1–100, within output caps. | generate |
| `/remind N` | Schedule the captured content as a local notification N minutes after submission; required integer range 1–525600. | action |
| `/toc` | Insert a nested Markdown list of headings in captured context; support ATX and Setext headings, ignore fenced code, make deterministic duplicate-safe anchors. | insert |
| `/split "delimiter"` | Replace literal delimiter occurrences with LF; preserve segment whitespace and empty segments. Empty delimiter is invalid. | transform |
| `/join "separator"` | Replace logical line breaks with the separator, including blank lines; a final line terminator is not an extra item. Empty separator is valid. | transform |
| `/daily` | Insert `# Sat, Sept 12` plus two trailing newlines; attach a real default calendar emoji landmark to the heading line upon Merge. | generate |
| `/count-characters` | Report user-perceived Unicode characters including and excluding whitespace; no document insertion. | report |
| `/count-words` | Report words using Unicode-aware word segmentation; count contractions as one word and omit punctuation-only segments. | report |
| `/count-lines` | Report logical lines and non-empty lines; empty content is zero, final terminator adds no item, visual wrapping is irrelevant. | report |
| `/random [N]` | Insert N independently sampled characters from an editable unambiguous alphanumeric alphabet; default 12, integer range 1–4096. | generate |
| `/tts [N]` | Convert each tab to N spaces; default 4, integer range 1–16. This is fixed substitution, not tab-stop alignment. | transform |
| `/stt [N]` | Convert complete groups of N leading ASCII spaces into tabs; default 4, range 1–16; preserve remainder and interior prose spaces. | transform |
| `/trim` | Remove horizontal whitespace at both ends of each line, including indentation; retain line breaks and interior spacing. | transform |
| `/trim-start` | Remove leading horizontal whitespace from each line. | transform |
| `/trim-end` | Remove trailing horizontal whitespace from each line. | transform |
| `/strip-ws` | Remove all Unicode whitespace, including line breaks, joining remaining characters. | transform |
| `/blank-lines` | Remove whitespace-only lines; preserve non-empty lines exactly and preserve terminal-newline presence when any remain. | transform |
| `/escape` | Escape HTML text characters `&`, `<`, `>`, double quote, and apostrophe once per input character. | transform |
| `/unescape` | Decode supported HTML named entities and valid decimal/hex numeric entities in one pass; leave unknown/invalid entities unchanged. | transform |
| `/url-md` | Convert bare HTTP(S) URLs to `[host/path](url)`; preserve query/fragment in destination, skip existing links/images/code/autolinks, exclude trailing prose punctuation. | transform |
| `/sort-az` | Stable alphabetical ascending line sort using captured locale; ignore case for comparison. | transform |
| `/sort-za` | Stable alphabetical descending line sort; equal keys preserve input order. | transform |
| `/sort-09` | Stable ascending sort by first finite signed decimal/exponent number on each line. | transform |
| `/sort-90` | Stable descending numerical sort by the same rule. | transform |
| `/upper` | Uppercase letters throughout raw content with Unicode casing. | transform |
| `/lower` | Lowercase letters throughout raw content with Unicode casing. | transform |
| `/title` | English title case per non-empty line; lowercase editable minor-word list except first/last word; preserve all-uppercase acronyms. | transform |
| `/sentence` | Capitalize the first letter at block start and after sentence-ending punctuation; preserve all other casing, account for closing quotes and common abbreviations. | transform |
| `/json [N]` | Parse and pretty-print JSON with N spaces; default 2, integer range 1–8; invalid or unsafe precision-losing JSON yields a diagnostic. | transform |
| `/json-min` | Parse and minify JSON while preserving JSON values and number precision. | transform |
| `/summarize [short\|N]` | Summarize key facts, decisions, and action items; default concise prose, `short` requests one short paragraph, N requests 1–20 bullets. | transform/model |
| `/proof` | Correct spelling, grammar, and punctuation while preserving meaning, voice, and structure. | transform/model |
| `/explain` | Explain dense or unfamiliar content in clearer language, retaining key terminology and identifying uncertainty. | transform/model |
| `/simplify` | Rewrite in plainer language while retaining information. | transform/model |
| `/concise` | Remove repetition and filler while preserving meaning and tone. | transform/model |

Sorting retains duplicates; whitespace-only lines follow nonblank lines in original order for every direction. Numerical nonblank lines without a finite number follow numbered lines, before blanks, and retain their order. All line transforms recognize CRLF as one separator and lone CR/LF as separators. Sort/join/count share terminal-line semantics; transforms preserving line boundaries preserve the original separators where possible, and sort uses the first encountered separator plus the original terminal-newline convention. Split deliberately emits LF.

Case transforms operate on raw text; they can change URL paths and code identifiers. Descriptions must not promise Markdown semantic preservation. Sentence case is documented as a heuristic, with fixtures for abbreviations and quotations. Deterministic tools use English formatting/minor-word defaults where specified; they do not require a model.

### 2. Versioned inputs, editable formatting, and arguments

Introduce manifest schema 3 and entry contract 2 for new packages, preserving decoding and execution of contracts 1 and schema 1/2. Capture the submission instant once in the app, plus local calendar components, weekday, offset and IANA zone, and locale. Expose bounded immutable values to scripts; keep ambient Date disabled. Put `FORMAT` at the top of each timestamp script (for example `MMM D, h:mma`, `ddd, MMM D`, and `h:mma`), with a small documented formatter and editable English name tables using `Sept`. `/daily` exposes the same formatter, a header template, and emoji constant. Midnight/noon, DST, and time-zone capture are fixture-tested.

Add an optional manifest argument schema, with integer/string/enum types, defaults and limits, and frozen `input.arguments`. Contextual arguments use a labeled anchored argument field separate from the adjustable content block; command-line examples are accepted through that field rather than parsing arbitrary note characters. The command and its single acceptance separator remain excluded according to existing scope normalization. Contained generators parse only their owned argument text. Quoted strings preserve spaces, `""` is empty, and documented escapes are `\n`, `\r`, `\t`, `\"`, and `\\`; unknown escapes and unclosed quotes are errors. Split/join require an argument, so omitted and empty are distinguishable. Validation runs before any side effect.

Every argument field and associated control must work without a pointer. Accepting a contextual command with arguments focuses its first argument field. Tab and Shift-Tab traverse all argument fields and invocation controls in a stable order with visible focus and no trap. Ordinary editing/navigation keys operate within fields, and the existing explicit Submit shortcut works from every field. Escape returns focus to the invocation in the editor without running the tool or discarding entered values; a keyboard-accessible action can reopen the fields. Explicit invocation dismissal still discards ephemeral arguments. Invalid submission focuses the first invalid field and exposes its error to VoiceOver. Verify the complete accept/edit/traverse/submit/error-correct/return flow using only the keyboard, including offscreen/re-mounted controls.

Provide captured entropy as bounded app-generated random bytes (at most 16 KiB) for `/random`, with rejection sampling for unbiased alphabet indexing; never derive a long string solely from the existing UUID. Preserve reproducibility when a fixture injects identical entropy. Expose bounded pure text services, only where needed for Unicode segmentation and locale collation unavailable in QuickJS: compute exact-content segment boundaries and stable comparison keys in the app and inject primitive bounded data requested by the manifest. No callbacks or native objects cross the process boundary. Unsupported service/locale data fails explicitly rather than silently falling back to ASCII counts. Count characters using extended grapheme clusters and words using the captured locale's documented segmentation rules.

Alternative considered: parse options from contextual text or weaken the sandbox to use OS APIs directly. Separate arguments avoid accidentally exporting or transforming option strings; captured values preserve isolation and predictable testing.

### 3. Declarative host actions and result lifecycle

Contract 2 results are an exclusive tagged union: text output (optionally a bounded landmark attachment), report text, or one typed host-action request. Host actions are limited to `clipboard.rich`, `file.export`, and `notification.schedule`. The worker returns bounded inert data, never a path, credential, callback, executable, or generic HTTP request. Scripts transform content and construct requests; app-composed services validate and execute them. Manifests declare supported actions; declarations alone are not authorization. The host checks the immutable package, declared action, exact captured content, generation and resource limits. Custom/edited packages can use the same actions; their invocation identifies the action and destination class before Submit. Validation, discovery and model output never trigger actions.

Keep the existing pending Merge/Dismiss pipeline for text. Reports and completed actions instead show noncanonical feedback and a Done control that removes the invocation token/separator only through an undoable transaction; captured source remains intact. Action feedback is reported only after actual acknowledgement. Native save-panel cancellation retains an editable invocation. Undo, Done, relaunch, re-rendering, and Dismiss never replay an external action. Presentations state that completion does not imply an external action can be undone.

An action generation gets one dispatch and one recorded acknowledgement. Cancellation before dispatch prevents the action; after dispatch, cancellation stops waiting where possible but does not claim an acknowledged external effect was reversed. Unacknowledged effects remain explicitly unknown and are not automatically retried. Persist bounded action status/receipts before and after dispatch where recovery matters; interrupted actions restore feedback without redispatch. A user-initiated retry is a new generation; unknown outcomes must not be presented as confirmed failure or success.

Alternative considered: return status strings through ordinary canonical output. A dedicated report/action path avoids polluting the train of thought and avoids treating Merge as consent after a side effect has already happened.

### 4. Native service behavior

- Rich copy: render a documented Markdown subset through a bounded, dependency-free tokenizer into RTF/HTML plus readable plain text. Vet the policy with native round-trip and adversarial fixtures; this is not a full CommonMark parser. Disable raw executable HTML, resource fetching, and remote images. Clipboard updates occur once all representations are ready; unsupported Markdown has readable fallback. Verify common formatting using native attributed-string reads and representative paste targets.
- Export: use a native save panel, a sanitized filename suggestion from the first heading/non-empty line, default `note.md`, exact UTF-8 content, and ordinary overwrite confirmation. No automatic overwrite or arbitrary script-supplied path. Cancellation does not report success.
- Reminder: request notification permission when first used, schedule through the OS with a stable per-generation identifier and absolute deadline computed from captured submission time, and acknowledge only when accepted. Store a bounded private receipt and captured full text needed for notification detail; show a grapheme-safe preview in the notification. OS scheduling survives app exit; actual delivery follows notification settings/Focus and must not be promised at an exact second. Notification activation opens Jort and shows the captured reminder even if original text was edited. No long-lived JS timer. Provide cancellation from completion feedback while pending; explain if already delivered. Receipts expire after delivery/dismissal or a bounded retention interval.
- Daily: text is previewed using normal publication. Merge inserts the header and assigns the emoji to the header's stable LineID atomically in JortDocument; Undo/Redo restores text and landmark together. Pending output has no permanent landmark. Each invocation explicitly creates a new entry; no whole-document duplicate-date scan.

### 5. Markdown, JSON and model implementation

Use one bounded Markdown tokenizer/parser policy for rich copy, TOC and URL conversion; do not fetch URL titles. TOC hierarchy follows observed heading levels with a stack, and anchor slugs lowercase text, remove Markdown decoration/punctuation, replace whitespace with hyphens, and suffix collisions `-1`, `-2`, including collisions with already-suffixed headings. No headings gives a report, not an empty replacement.

JSON formatting must not silently change large integers. Use a number-token-preserving parser/formatter or reject numbers that the implementation cannot round-trip exactly. Do not imply JSON.parse/stringify alone preserves arbitrary precision. Invalid JSON produces a bounded location diagnostic and no replacement.

Ship model packages through the existing model catalog and connection, with editable instructions and existing bounded context/provider-error/cancellation behavior. They receive only captured content and explicit arguments. Treat embedded instructions in note text as source material. Explain does not browse or claim external verification. All model output remains pending explicit Merge.

### 6. Compatibility and rollout

Retain stable IDs and existing source for legacy `/date`, `/uuid`, `/calc`, `/sort`, `/dedupe`; fresh installations disable these compatibility entries by default. On upgrade, persist their effective previous enablement before changing defaults. `/time` keeps its ID but increments version and opts into contract 2; never declare compatibility with old pending state unless field/mode migration is proven. Keep existing `/ask` and `/rewrite` available unchanged. User overrides and explicit enablement always win. New catalog collisions use existing diagnostics rather than renaming custom commands or discarding overrides.

Version all IPC participants together and preserve the contract-1 execution adapter. Protocol envelopes remain independently bounded; include limits for new arguments, local fields, segmentation/collation data, entropy, action payloads, and their summed size. Oversized expansions fail without partial effect. Keep worker/broker entitlements unchanged and re-run containment coverage whenever the protocol or service boundary changes.

## Risks / Trade-offs

- Broader feature scope than adding scripts → stage contracts and native actions before catalog completion; all stages are required for this change.
- Native actions cannot be undone like text → explicit action descriptions, receipts and no replay; preserve captured document text.
- Unicode/Markdown edge cases → shared fixtures and bounded parser behavior rather than unqualified correctness claims.
- Format/default changes could surprise existing users → explicit compatibility migration and preserve editable overrides.
- Notification delivery depends on OS settings → typed actionable failures and native qualification; no completion based on mocks alone.
- Large catalogs can be noisy → concise command names, specific descriptions, ordinary Settings enable/disable and search behavior.

## Migration Plan

1. Add backward-compatible schema, inputs/results and versioned protocol behind validation.
2. Add argument/report/action lifecycle and host adapters; qualify boundaries before enabling action packages.
3. Add catalog packages, override-preserving default migration, and help/examples.
4. Run focused checks plus the repository gate and native action qualification before release.
5. If rollout fails, disable new action packages without deleting user packages, receipts, document text, or pending canonical output. Unsupported new invocation metadata must degrade to preserved ordinary text under the existing recovery policy; never replay actions on downgrade/relaunch.

## Open Questions

The user has approved trying separate argument fields with keyboard navigation required. Evaluate their usability in the first working build and refine the interaction based on feedback. Implementation must select/reuse parsers and prove signing/notification behavior in the actual app build. Any dependency or behavior adjustment must update these artifacts before declaring its task complete.
