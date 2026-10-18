# Tool packages

A package is a directory with `tool.json` and either `tool.js` (JavaScript) or
`instructions.txt` (model). The bundled tools in
`Jort/Resources/Tools` are complete examples. Settings → Tools edits the same
packages that the editor runs. Customize creates a user override; deleting that
override restores the current bundled package. Application updates preserve user
packages. Installed generations live under the app data directory's `Tools/`.
The atomic `index.json` selects current generations; older files are retained for
recovery. The registry's `install(from:)` imports a package directory.

The version-one manifest requires `schemaVersion`, a reverse-DNS `id`, a positive
integer `version`, `name`, slash-prefixed `command`, `description`, `entryContract`,
`inputMode`, `outputOperation`, `maximumInputBytes`, `maximumOutputBytes`, and
`maximumOutputLines`. The four input mode values are `contained`, `contextual`,
`ephemeralSingleLine`, and `ephemeralMultiline`. Output operations are
`replace-invocation`, `replace-context`, and `insert-at-invocation`.

```javascript
export default async function(input) {
  return {output: input.content.toUpperCase()};
}

// Optional. Runs before source is locked or the main entry point is called.
export async function validate(input) {
  return input.content.trim() ? {output: ""} : {error: "Enter some text."};
}
```

Both entry points receive a frozen object with `content`, `clock` (captured UTC
ISO-8601 string), `uuid` (captured lowercase UUID), and a read-only `cancelled`
getter. Contract 1 returns exactly one of `{output: string}` or `{error: string}`
and has no separately parsed arguments. The host owns publication and Merge; scripts
never receive the document or editor. Empty output is a successful result.

The editor removes exactly one leading ASCII space from extracted content before
validation and execution. Additional spaces, tabs, newlines, and all other text
are preserved; the canonical input in the document is never trimmed.

Execution has a 16 MiB QuickJS heap, 512 KiB engine stack, five-second wall
timeout, CPU limit, and manifest input/output bounds. Cancellation terminates the
disposable run. There are no filesystem, network, process, native bridge, module
loading, `eval`, or function-constructor facilities. No engine standard-library
or operating-system bindings are linked.

Every validation and execution uses a fresh QuickJS worker behind Jort's private,
independently sandboxed broker. Only that disposable worker links the native
engine; it receives the normalized package contract, source, exact input,
captured clock/UUID, correlation identity, and declared bounds—never a document,
credential, provider, path, URL, bookmark, or native application object. The
broker owns timeout, cancellation, termination, and reaping. Settings uses the
same boundary for fail-closed source validation, and provider transports and
credentials remain in the separate lazy model path.

Jort intentionally does not promise a whole-process memory ceiling or implement
a process-memory watchdog. Ordinary JavaScript allocation remains constrained by
the QuickJS heap limit; macOS manages native allocations and system memory
pressure. A worker allocation failure, crash, or lost connection publishes no
partial output. This trade-off is accepted for bundled and user-authored tools;
public/community package import remains disabled pending the signed release gate.

The engine source, MIT license, exact local patch, reproducible import procedure,
and review policy are pinned under `Vendor/QuickJS` and
`docs/quickjs-security-review.md`.

`compatibleVersions` may list up to 32 older positive package versions that map
unchanged to the current entry, input, and output contracts. Completed output is
never rerun during migration. Without a compatible mapping, inputting source
becomes plain text; completed output is retained and invocation-owned source is
removed. Contextual source survives this fallback.

The compatibility `/date` format is `YYYY-MM-DD` in UTC. Calculator
power is right associative, binds more tightly than a leading unary sign, and
rejects non-finite results. Sort uses literal JavaScript string ordering; dedupe
keeps the first exact line. Neither normalizes whitespace or Unicode.

Compatibility `/date` and `/uuid` append the exact `input.content` after their generated value,
including spaces and newlines. New tools created in Settings default to enabled;
saving registers the package for completion in open editors without executing it.

The expanded catalog keeps `/date`, `/uuid`, `/calc`, `/sort`, and `/dedupe` as
compatibility packages. Fresh installations disable these five; explicit user
enablement and overrides take precedence. `/ask` and `/rewrite` remain unchanged.
`/time` keeps its ID but moves to package version 2, schema 3 / entry contract 2:
it inserts captured local time without appending arguments or other content.
It does not declare compatibility with version-one pending invocations.

## Model executors (schema 2)

Schema 2 adds `executor: "javascript" | "model"`. Legacy manifests without an executor remain JavaScript. Model packages use `instructions.txt` instead of `tool.js`, and declare a stable `modelID`. Instructions are plain text, nonempty, and limited to 32 KiB. The bundled version-one model catalog contains GPT-5.4 Mini (the default), GPT-5.4, and Claude Sonnet 4.6. Unknown model selections remain inspectable and editable, but do not execute or silently switch models.

`/ask` uses contained inline input and inserts output at the invocation. `/rewrite` uses contextual input and replaces its captured context on Merge. Both use the ordinary tool registry, settings, source locks, canonical output, persistence, and history. Submitted generations capture their package and continue using that captured configuration after a Settings edit. Older saved calls retain their original input behavior.

Model execution sends only the selected model, instructions, and captured content in one nonstreaming OpenRouter chat completion. It has no document, history, filesystem, JavaScript, or tool-calling capability. Global output-token limits are 8,192, further constrained by the catalog and tool byte limit; existing tool byte and line limits still apply. Transport decoding is bounded to six times the output byte cap plus 64 KiB, with an absolute 8 MiB ceiling, 60-second request and 90-second resource timeouts, and no HTTP redirects.

Schema 3 model packages also receive separately captured arguments. The five new
model examples are `/summarize`, `/proof`, `/explain`, `/simplify`, and `/concise`.
Their editable prompts treat embedded source instructions as text to process,
preserve factual qualifications, and return pending text for explicit Merge.
`/explain` does not browse or claim external verification. They use the existing
model catalog and connection; no package creates a provider connection.

## Schema 3 / entry contract 2

New examples use explicit `executor`, `schemaVersion: 3`, and `entryContract: 2`.
The additional manifest fields are optional. This is a complete argument example:

```json
{
  "schemaVersion": 3,
  "executor": "javascript",
  "id": "org.example.join",
  "version": 1,
  "name": "Join lines",
  "command": "/join-example",
  "description": "Join logical lines with a literal separator",
  "entryContract": 2,
  "inputMode": "contextual",
  "outputOperation": "replace-context",
  "maximumInputBytes": 262144,
  "maximumOutputBytes": 262144,
  "maximumOutputLines": 10000,
  "arguments": [
    {
      "name": "separator",
      "type": "string",
      "label": "Separator",
      "description": "Required; an empty string is allowed",
      "required": true
    }
  ]
}
```

Its self-contained `tool.js` can be:

```javascript
export async function validate(input) {
  return typeof input.arguments.separator === "string"
    ? {output: ""}
    : {error: "Supply a separator, including an empty string if desired."};
}

export default async function(input) {
  const validation = await validate(input);
  if (validation.error) return validation;
  if (!input.content) return {output: ""};
  const lines = input.content.split(/\r\n|\r|\n/);
  if (/(?:\r\n|\r|\n)$/.test(input.content)) lines.pop();
  return {output: lines.join(input.arguments.separator)};
}
```

Argument declarations have `name`, `type` (`integer`, `string`, or `enum`),
`label`, and optional `description`, `defaultValue`, `minimum`, `maximum`,
`required`, and `choices`. Integer values cross the boundary as JSON numbers;
string and enum values as JSON strings, without Swift enum wrappers. Defaults
and ranges are validated before execution. Keep a script's editable fallback
constant consistent with the corresponding manifest default.

For new contract-two calls, type arguments directly after the command, on the
same logical line. The blue call owns the command and inputs; teal context is
separate. Context defaults to the text before the command on its line, or the
previous paragraph when the command starts a line. Drag the existing context
handles to include text before or after the call. `input.content` contains only
those context fragments, excluding the whole call and pending output. Context
whitespace is preserved. Contained generators parse their owned input as
arguments; zero-argument generators reject non-whitespace input. Selecting a
completion with Return or a click immediately runs no-argument contained
JavaScript generators, showing pending output for Merge. Legacy Date and UUID
work the same way. Space only accepts a completion; tools with arguments,
context, or model input still wait for Shift-Return. Once a call is accepted,
ordinary Return resumes notes on a new line without extending its inputs.

Contextual model tools also accept an optional free-text question after their
declared arguments: `/explain What does the Kubernetes reference mean?`.
Execution freezes this as `instruction`, separate from `content`; the provider
receives explicitly labeled request and context, not modified system instructions.
The question is limited to 16 KiB and is not available to JavaScript tools.

Quoted arguments preserve spaces. `""` supplies an empty string; omission is
different. Supported escapes are `\n`, `\r`, `\t`, `\"`, and `\\`; unknown
escapes and unclosed quotes fail validation. For example `/split ".*"` uses a
literal delimiter, `/join " · "` keeps spaces around the dot, and `/join ""`
concatenates. Input help beneath active calls starts with the tool description
and adds short prompts from argument descriptions or labels, including useful
ranges and defaults. With a collapsed caret in a contextual call,
Tab focuses the start handle and Shift-Tab the end handle. Tab cycles between
handles and back to inputs; arrow keys move the focused handle. Escape or Return
returns to inputs without cancelling. Shift-Return runs from either inputs or a
handle. Ordinary Shift-arrow and Option-Shift-arrow selection, copying, and
pasting keep their native editor behavior. Contract-one and older saved nil-call
invocations retain the legacy fields and scope behavior.

The frozen input retains contract-one `content`, `clock`, `uuid`, and `cancelled`.
Contract two adds `arguments` and only requested captured data:

| Manifest `capturedData` | Input field | What an editable script can use |
| --- | --- | --- |
| `localTime` | `localTime` | `year`, `month`, `day`, `weekday` (0 = Sunday), `hour`, `minute`, `second`, `timeZone`, `locale` |
| `entropy` | `entropy` | At most 16 KiB of app-generated random bytes, each 0–255 |
| `analysis` | `analysis` | `characters`, `charactersWithoutWhitespace`, `words`, `alphabeticalOrder`, `alphabeticalRanks` |

`localTime` describes the submission instant in the captured time zone. Ambient
`Date` stays disabled. The timestamp examples expose `FORMAT` plus English month
and weekday tables; supported tokens are `YYYY`, `MMM`, `MM`, `D`, `DD`, `ddd`,
`H`, `HH`, `h`, `hh`, `mm`, `ss`, and `a`. `MMM` uses `Sept`; `h` is a 12-hour
hour without leading zero and `a` is lowercase am/pm. Formats such as
`YYYY-MM-DD HH:mm:ss` are ordinary script edits. `/daily` additionally exposes
`HEADER_TEMPLATE` and `LANDMARK_EMOJI`; its default output is `# Sat, Sept 12`
followed by two newlines, with a metadata-only calendar landmark on line 0.

Character counts use extended grapheme clusters, so a family emoji or decomposed
accent is one displayed character. Word analysis uses the captured locale,
counts contractions once, and omits punctuation-only segments. Alphabetical
order is a stable ascending permutation of logical line indices using
case-insensitive locale collation; ranks are indexed by original line, with
equal ranks for tied collation keys. Descending sort reverses the rank comparison
while retaining original index order for ties. Missing or unsupported analysis
fails explicitly; these scripts do not silently substitute ASCII processing.

## Results and native actions

Return exactly one result variant:

```javascript
// Canonical pending text, requiring explicit Merge.
return {output: "Generated text"};

// Text may also attach one landmark to a zero-based output line on Merge.
return {output: "# Heading\n\n", landmark: {line: 0, emoji: "📅"}};

// Presentation-only feedback; captured source is retained.
return {report: "Words: " + input.analysis.words};

// An inert request. Only the native host can perform and acknowledge the effect.
return {action: {kind: "clipboard.rich", content: input.content}};

// A bounded invocation-local diagnostic, with no partial result.
return {error: "Enter an integer from 1 to 100."};
```

Declare requested action kinds in the manifest's `hostActions` array. The only
allowed kinds are `clipboard.rich`, `file.export`, and `notification.schedule`.
An action has `kind` and exact captured `content`; reminder adds integer `minutes`
(1–525600), export may add a suggested `filename`. A filename is not a path.
For example the bundled exporter derives a sanitized `.md` suggestion but the
native save panel chooses the destination, confirms overwrite, and offers `.txt`
without stripping Markdown. Rich copy asks the host to prepare HTML, RTF, and
readable plain text without executing raw HTML or fetching resources. Reminder
asks the OS to schedule captured text after the submission instant; notification
settings affect delivery, and scheduling acknowledgement does not promise an
exact delivery second.

Manifest declarations do not grant authority. The host validates package,
generation, content, declaration, and bounds before dispatch. `validate` must
never return an action or claim completion. Scripts cannot access the clipboard,
save destination, notification center, or native callbacks. Reports and actual
action acknowledgements stay outside canonical text. Done removes only the
invocation token/separator through an undoable edit; Undo, Dismiss, relaunch, or
rendering never replay an action or claim to reverse an external effect.

The native rich-copy renderer has a deliberately small subset: ATX headings,
single-line block quotes, unordered list markers, fenced code, single-backtick
inline code, `*`/`_` emphasis, `**`/`__` strong text, and ordinary inline links.
Active link schemes are HTTP, HTTPS, and mailto. Images become readable alt text
without loading image data. Raw HTML is escaped; unsupported or nested constructs
fall back to literal text. Setext headings, reference links, tables, and nested
list layout are not currently promised as rich clipboard formatting. The TOC and
URL examples below recognize additional source constructs for extraction or
protection; recognition does not imply the native clipboard renders all of them.

## Editable catalog examples

All 40 new-catalog commands below are ordinary packages. Each JavaScript source
is self-contained; small helpers are intentionally repeated to make it possible
to copy and edit one package without a shared dispatch dependency.

| Commands | Defaults and behavior |
| --- | --- |
| `/now`, `/today`, `/time`, `/daily` | Captured local formats; no arguments; generator-only output |
| `/lorem [N]` | 1–100 standard paragraphs separated by blank lines; default 1 |
| `/random [N]` | 1–4096 characters from editable unambiguous `ALPHABET`; default 12; unbiased byte rejection sampling; insufficient entropy fails |
| `/copy-rich`, `/export`, `/remind N` | Clipboard, user-selected file, or OS notification requests; exact captured source retained |
| `/toc` | Insert nested links for ATX and Setext headings; no headings gives a report |
| `/split "delimiter"`, `/join "separator"` | Literal delimiter/separator; preserve whitespace and empty interior items; split emits LF |
| `/count-characters`, `/count-words`, `/count-lines` | Noncanonical Unicode and logical-line reports |
| `/tts [N]`, `/stt [N]` | Width 1–16, default 4; fixed tab substitution or complete leading-space groups, not tab-stop alignment |
| `/trim`, `/trim-start`, `/trim-end` | Horizontal edge whitespace per line; `/trim` removes indentation too |
| `/strip-ws`, `/blank-lines` | Remove all Unicode whitespace, or only whitespace-only lines respectively |
| `/escape`, `/unescape` | One-pass HTML text escaping or supported entity decoding; unknown/invalid entities remain literal |
| `/url-md` | Bare HTTP(S) links labeled host/path, keeping query/fragment in destination; skip existing Markdown constructs |
| `/sort-az`, `/sort-za` | Captured-locale case-insensitive alphabetical order; stable ties; blanks last |
| `/sort-09`, `/sort-90` | First finite signed decimal/exponent number; stable ties; unnumbered nonblank lines then blanks |
| `/upper`, `/lower`, `/title`, `/sentence` | Raw Unicode/English casing; may change code or URL paths; editable minor words/abbreviations |
| `/json [N]`, `/json-min` | Validated JSON formatting, 1–8 indentation spaces (default 2), or minification; exact number tokens retained |
| `/summarize [short\|N]` | `length` enum: `default` concise prose, `short` one paragraph, `1`–`20` that many bullets |
| `/proof`, `/explain`, `/simplify`, `/concise` | Correct language, clarify concepts, simplify wording, or remove filler with editable model prompts |

Line utilities recognize CRLF as one separator and lone CR/LF as separators.
Empty content has zero logical lines. A final separator terminates the last item
and does not create an extra one. Interior blank items remain unless explicitly
removed. Boundary-preserving transforms keep mixed separators; sort uses the
first encountered separator and retains terminal-newline presence. Sort never
deduplicates. Numerical nonblank lines without a finite number keep their order
after numbered lines, before blanks, in either direction.

Horizontal trim means tabs, Unicode space separators, and BOM; it retains
vertical controls and Unicode line separators. All-whitespace removal and blank
classification also recognize Unicode NEL (`U+0085`), which JavaScript `\s`
alone omits. NEL and Unicode line/paragraph separators are removed by `/strip-ws`
but are not additional logical-line separators for join/sort/count.

The Markdown examples recognize backtick/tilde fences with matching marker and
closing length, indented code, ordinary top-level headings, inline backtick spans,
links/images/reference links and angle-bracket autolinks. TOC hierarchy uses the
observed heading levels rather than inserting phantom levels. Its slugs remove
decoration/punctuation, lowercase Unicode text, hyphenate whitespace, and check
all previously used anchors, including already-suffixed names. URL conversion
removes trailing prose punctuation and unmatched closing parentheses, preserves
balanced URL parentheses, and is safe to rerun on its generated links. These
editable bounded examples do not implement every CommonMark extension or fetch
URL titles. Unsupported constructs remain ordinary source text.

Title case preserves all-uppercase acronyms and uses the editable `MINOR_WORDS`
list except at the first/last word on each line. Sentence casing preserves other
casing and uses an editable abbreviation/initial/closing-quote heuristic, not a
grammar model. HTML decoding requires semicolons and happens only once:
`&amp;lt;` becomes `&lt;`. NUL, surrogate, out-of-range, and noncharacter numeric
entities remain unchanged. The supported named table is visible in `unescape`.

JSON examples use a readable recursive-descent parser (maximum nesting 128),
not `JSON.parse`/`JSON.stringify` on numeric values. Original number and string
tokens are emitted after validation, so `9007199254740993123456789`, `1e400`,
and `-0` retain their precision and spelling. Strings and duplicate keys also
retain their original order/tokens. Invalid syntax, bad indentation, or excessive
nesting yields a bounded location diagnostic and no replacement.
