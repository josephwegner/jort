## ADDED Requirements

### Requirement: The expanded catalog is discoverable and editable
Jort SHALL ship the 40 commands enumerated in the design catalog as valid editable packages with concise command names, specific descriptions, argument help, explicit input/result modes, and ordinary enablement and override behavior. `/copy-rich` SHALL occur once. `/ask` and `/rewrite` SHALL remain available unchanged.

#### Scenario: User inspects the catalog
- **WHEN** completion or Settings displays an enabled package
- **THEN** it shows the command and readable behavior description, including action type where applicable
- **AND** the user can inspect and customize its JavaScript or model instructions through existing authoring controls

#### Scenario: A developer learns from a bundled example
- **WHEN** a developer opens a bundled script to build their own tool
- **THEN** the script is self-contained, uses descriptive names and small understandable functions, and exposes customization constants clearly
- **AND** comments explain non-obvious behavior without compressed code or hidden command-dispatch machinery

#### Scenario: Existing installation upgrades
- **WHEN** bundled defaults change
- **THEN** user overrides and explicit enablement win, prior effective enablement for compatibility tools is preserved, and fresh installations disable the five compatibility tools
- **AND** collisions produce existing registry diagnostics without deleting or renaming user packages
- **AND** old saved results are preserved without execution

### Requirement: Timestamp templates use captured local time
`/now`, `/today`, and `/time` SHALL use one submission-time local calendar capture and a clearly identified editable JavaScript FORMAT constant. Defaults SHALL use English weekday/month abbreviations including `Sept`, 12-hour hours without leading zero, two-digit minutes, and lowercase am/pm without a preceding space.

#### Scenario: Timestamp formats are generated
- **WHEN** the captured local instant is Saturday September 12 at 10:28 in the morning
- **THEN** `/now` returns `Sept 12, 10:28am`, `/today` returns `Sat, Sept 12`, and `/time` returns `10:28am`
- **AND** changing the machine clock or time zone during execution does not change that run's capture

#### Scenario: Format is customized
- **WHEN** a user edits FORMAT to include a year, seconds, or 24-hour hour token
- **THEN** the next submission uses the edited format without a native app change
- **AND** midnight, noon, year boundaries, and DST transitions are formatted from captured components

### Requirement: Generators validate bounded output arguments
`/lorem` SHALL accept 1–100 paragraphs, default 1, separated by blank lines. `/random` SHALL accept length 1–4096, default 12, using bounded captured cryptographic entropy and unbiased sampling from an editable unambiguous alphanumeric alphabet. Generators SHALL emit only generated content and obey package output limits.

#### Scenario: Valid generation
- **WHEN** `/lorem 3` or `/random 12` is submitted
- **THEN** the former produces three paragraphs and the latter exactly twelve permitted characters
- **AND** output uses the normal pending Merge lifecycle

#### Scenario: Invalid argument or inadequate entropy
- **WHEN** a count is negative, fractional, out of range, or the captured entropy cannot produce the requested output
- **THEN** the tool fails with a bounded diagnostic and no partial output
- **AND** it never falls back to clock- or UUID-derived pseudo-random text

### Requirement: Split and join preserve deliberate content
`/split` SHALL replace literal non-empty delimiters with LF without trimming segments. `/join` SHALL replace logical line separators with an explicitly supplied separator, including an empty separator, retaining empty interior items and ignoring one final terminator as an extra item. Quoted arguments and documented escapes SHALL preserve separator intent.

#### Scenario: Empty segments are preserved
- **WHEN** `/split ","` receives `a,, b`
- **THEN** the result is `a\n\n b`
- **AND** `/join ","` on `a\n\n b\n` returns `a,, b`

#### Scenario: Literal delimiter resembles a pattern
- **WHEN** `/split ".*"` receives content containing that exact string
- **THEN** only literal occurrences split the content; no regular expression executes

### Requirement: Whitespace tools have distinct semantics
Jort SHALL provide `/tts`, `/stt`, `/trim`, `/trim-start`, `/trim-end`, `/strip-ws`, and `/blank-lines` with the design catalog's exact behavior. Indentation width SHALL default to 4 and accept integers 1–16. Trim commands SHALL remove horizontal edge whitespace per line, with `/trim` removing indentation as well as trailing spaces; only `/strip-ws` SHALL remove all whitespace including newlines.

#### Scenario: Indentation and interior spaces differ
- **WHEN** `/stt 4` receives six leading spaces followed by words separated by two spaces
- **THEN** it replaces four leading spaces with a tab, preserves the two remaining leading spaces, and preserves interior spaces
- **AND** `/tts 4` replaces each tab with exactly four spaces

#### Scenario: Whitespace removal is selected
- **WHEN** `/trim`, `/trim-start`, or `/trim-end` processes a line with whitespace on both edges
- **THEN** only the specified edges are removed and line separators remain
- **AND** `/strip-ws` removes interior and line-breaking whitespace as well

#### Scenario: All lines are blank
- **WHEN** `/blank-lines` receives only empty or whitespace-only lines
- **THEN** it returns a valid empty text result using existing explicit Merge behavior

### Requirement: Sort tools are stable and preserve items
Jort SHALL provide `/sort-az`, `/sort-za`, `/sort-09`, and `/sort-90`. Alphabetical tools SHALL compare case-insensitively using captured locale collation. Numerical tools SHALL compare the first finite signed decimal/exponent number per line. Equal keys SHALL retain input order in either direction. Duplicates SHALL remain. Non-numeric lines SHALL follow numeric lines; whitespace-only lines SHALL follow all nonblank lines, each in original order. Sorting SHALL preserve terminal-newline presence and use the first line separator style.

#### Scenario: Numeric and alphabetical order differ
- **WHEN** lines `10`, `2`, `item`, and an empty line are sorted numerically ascending
- **THEN** numbered lines appear as `2`, `10`, followed by `item` and the blank line
- **AND** descending produces `10`, `2` followed by the same non-numeric and blank items

#### Scenario: Comparison keys tie
- **WHEN** case-insensitive alphabetical keys or extracted numeric values are equal
- **THEN** their original relative order is preserved even for descending sorts

### Requirement: Casing tools describe their raw-text effects
`/upper` and `/lower` SHALL perform Unicode casing throughout raw content. `/title` SHALL apply English title case per non-empty line using an editable minor-word list and preserving uppercase acronyms. `/sentence` SHALL capitalize sentence starts while preserving other casing using a documented punctuation/quote/abbreviation heuristic. Descriptions SHALL make clear that code and URLs can be affected.

#### Scenario: Title casing preserves an acronym
- **WHEN** `/title` receives `a guide to NASA`
- **THEN** it produces `A Guide to NASA`

#### Scenario: Sentence casing preserves existing internal casing
- **WHEN** `/sentence` receives `hello iPhone. welcome back!`
- **THEN** it produces `Hello iPhone. Welcome back!`

### Requirement: HTML and URL tools avoid double processing
`/escape` SHALL encode ampersands, angle brackets and both quote types once per input character. `/unescape` SHALL decode recognized named and valid numeric HTML entities in one pass, preserving unknown/invalid entities. `/url-md` SHALL wrap bare HTTP(S) URLs in Markdown, skip existing links/images/autolinks/code, and preserve destination query/fragment without fetching URLs.

#### Scenario: Entity decoding is one pass
- **WHEN** `/unescape` receives `&amp;lt;`
- **THEN** it returns `&lt;`, without recursively decoding to `<`

#### Scenario: URL ends a sentence
- **WHEN** `/url-md` receives `See https://example.com/docs.`
- **THEN** it returns `See [example.com/docs](https://example.com/docs).`
- **AND** rerunning the tool preserves the already-generated link

### Requirement: TOC generation preserves its heading source
`/toc` SHALL extract ATX and Setext headings outside fenced code, preserve hierarchy through nesting, and insert a Markdown link list at the invocation after Merge while retaining the original context. It SHALL generate deterministic collision-safe slugs and SHALL produce a noncanonical no-headings report when none exist.

#### Scenario: Duplicate headings exist
- **WHEN** context contains two headings named `Ideas`
- **THEN** their links use `#ideas` and `#ideas-1`
- **AND** heading-like text inside a code fence is excluded

#### Scenario: Source is retained
- **WHEN** generated TOC output is merged
- **THEN** the source headings and body remain intact
- **AND** Jort does not claim that generated fragment links imply native in-editor navigation

### Requirement: JSON formatting preserves values
`/json` SHALL pretty-print valid JSON with integer indentation 1–8, default 2. `/json-min` SHALL remove unnecessary JSON whitespace. Both SHALL preserve values, including number precision, or refuse inputs that cannot be represented faithfully.

#### Scenario: JSON cannot be formatted safely
- **WHEN** content is syntactically invalid or contains a number the selected implementation cannot round-trip exactly
- **THEN** the tool provides a bounded actionable diagnostic and leaves source unchanged

#### Scenario: Formatting is valid
- **WHEN** `/json 2` or `/json-min` receives valid representable JSON
- **THEN** the resulting JSON represents the same values with the requested whitespace style

### Requirement: Counts report Unicode and logical-line measures
`/count-characters` SHALL report extended grapheme cluster counts including and excluding whitespace. `/count-words` SHALL use captured-locale Unicode word segmentation, counting contractions once and excluding punctuation-only segments. `/count-lines` SHALL count logical rather than visually wrapped lines, report total and non-empty lines, count empty content as zero, and exclude a final terminator as an extra line. Counts SHALL remain noncanonical.

#### Scenario: Emoji and accents occur
- **WHEN** the block contains a multi-scalar family emoji or a decomposed accented character
- **THEN** each displayed grapheme contributes one character to the character count

#### Scenario: Line endings and blank lines occur
- **WHEN** `/count-lines` receives `a\r\n\r\nb\r\n`
- **THEN** it reports three lines and two non-empty lines
- **AND** visual wrapping does not change either result

### Requirement: Language tools reuse bounded model execution
Jort SHALL ship `/summarize`, `/proof`, `/explain`, `/simplify`, and `/concise` through the existing model executor with editable instructions and only captured content/arguments. Summarize SHALL preserve key facts/decisions/actions; proof SHALL correct language without discretionary stylistic rewriting; explain SHALL clarify concepts and acknowledge uncertainty; simplify SHALL retain information in plainer language; concise SHALL remove filler and repetition. All SHALL treat embedded instructions as source data and publish only pending text for explicit Merge.

#### Scenario: Summary length is supplied
- **WHEN** `/summarize short` or `/summarize 3` executes
- **THEN** the model is instructed to return one short paragraph or three bullets respectively
- **AND** an omitted argument requests concise prose, while out-of-range numeric counts fail validation

#### Scenario: Connection fails or output arrives late
- **WHEN** the existing model connection is unavailable, execution fails, or a late result arrives after cancellation
- **THEN** existing bounded failure and generation handling applies without source replacement
- **AND** no new provider connection is silently created
