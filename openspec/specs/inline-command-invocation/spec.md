# inline-command-invocation Specification

## Purpose

Define in-place slash-command recognition, completion, canonical and ephemeral input ownership, explicit asynchronous execution, connected presentation, locking, accessibility, and safe persistence behavior.

## Requirements

### Requirement: Invocation lifecycle authority is outside AppKit
Jort SHALL make a headless invocation reducer and coordinator authoritative for lifecycle transitions and asynchronous generation ownership, while AppKit SHALL be limited to native event translation and presentation of committed state.

#### Scenario: Invocation execution begins
- **WHEN** AppKit forwards an explicit Submit action with current native selection and focus facts
- **THEN** the headless lifecycle determines validation, locking, execution, cancellation, and presentation effects for one generation
- **AND** no AppKit controller independently assigns a lifecycle phase or owns the executor task

#### Scenario: Invocation state is restored
- **WHEN** sanitized persisted invocation metadata is loaded or recovered
- **THEN** the headless coordinator reconciles it with the current package contract and absence of prior-process jobs
- **AND** AppKit renders the resulting actionable state without re-executing previously published output

#### Scenario: Native integration reports stale document facts
- **WHEN** document anchors, hashes, package identity, or generation no longer match an outstanding lifecycle effect
- **THEN** the headless lifecycle rejects or reconciles the stale action deterministically
- **AND** AppKit cannot force publication or Merge by mutating its presentation state

### Requirement: Registered package commands are recognized in place
Jort SHALL recognize an exact slash command from an enabled valid tool package at its actual logical-line and character position when completion is explicitly accepted after committed text input and SHALL leave unmatched, unaccepted, pasted, abandoned, or provisional slash text as ordinary canonical text.

#### Scenario: Registered command is accepted
- **WHEN** a slash token at line start or after whitespace matches an enabled registered command and the user accepts its completion
- **THEN** Jort records invocation state using stable line identities and line-relative anchors
- **AND** decorates the actual token without adding characters to canonical text

#### Scenario: Slash text is unmatched or pasted
- **WHEN** slash text is not an exact enabled command or enters the document through plain-text paste
- **THEN** Jort treats every character as ordinary text
- **AND** creates no invocation metadata

#### Scenario: IME composition contains slash text
- **WHEN** slash text exists only in provisional marked text
- **THEN** Jort does not recognize or execute it until composition commits

### Requirement: Completion acceptance never implicitly executes
Jort SHALL offer registry-backed command completion after slash input, SHALL accept a selected command with Space or Return according to its declared input mode, and SHALL NOT execute as part of completion acceptance.

#### Scenario: Space accepts a canonical-input command
- **WHEN** the user selects a contained or contextual completion with Space
- **THEN** Jort completes the slash token and inserts the Space as canonical input
- **AND** does not run the command

#### Scenario: Return accepts a canonical-input command
- **WHEN** the user selects a contained or contextual completion with Return
- **THEN** Jort completes the slash token and inserts one canonical space without inserting a newline
- **AND** does not run the command

#### Scenario: Ephemeral completion is accepted
- **WHEN** the user accepts an ephemeral command with Space or Return
- **THEN** Jort consumes the acceptance key and focuses the command's anchored prompt
- **AND** inserts a canonical separator space after the command, outside its owned token range
- **AND** inserts no prompt content into canonical text

#### Scenario: Completion is dismissed
- **WHEN** the user presses Escape while completion is open
- **THEN** completion closes and focus remains in the editor
- **AND** already typed text remains unchanged

### Requirement: Contained input is canonical text in one owned range
Jort SHALL create an empty contained range immediately after an accepted contained command and SHALL grow that range through ordinary canonical editing performed from within it.

#### Scenario: User enters contained input
- **WHEN** the user types after accepting a contained command
- **THEN** the command and typed input form one invocation-owned canonical range
- **AND** the command is visually emphasized while input retains document typography

#### Scenario: Contained input crosses a newline
- **WHEN** the user presses Return while focused inside contained input
- **THEN** Jort inserts a canonical newline and extends the owned range onto the new logical line
- **AND** preserves ordinary gutter numbering for that line
- **AND** includes a trailing empty logical line in the wrapper when the caret is at its beginning

#### Scenario: User leaves contained input
- **WHEN** the user clicks or keyboard-navigates outside an unsubmitted contained invocation
- **THEN** the invocation remains valid but unfocused
- **AND** typing outside its range is not added to its content

#### Scenario: Command token becomes invalid
- **WHEN** the user edits an unsubmitted command so it no longer identifies a compatible enabled tool
- **THEN** Jort drops its invocation metadata and decoration
- **AND** leaves the command and contained input as ordinary canonical text

### Requirement: Contextual input uses one adjustable contiguous scope
Jort SHALL initialize contextual input to the accepted command's complete current logical line excluding its newline and SHALL expose movable start and end boundaries at any legal character positions around one excluded invocation token.

#### Scenario: Contextual command is accepted
- **WHEN** the user accepts a contextual command
- **THEN** Jort places its start boundary at the logical-line beginning and its end boundary at the logical-line end
- **AND** visibly wraps that exact contiguous range while excluding only the slash-command characters from submitted content

#### Scenario: Context boundary is dragged
- **WHEN** the user drags a text-selection-style start or end handle
- **THEN** Jort expands or contracts the contextual range to the chosen legal character boundary
- **AND** keeps the invocation active without replacing the ordinary typing selection

#### Scenario: Context boundary moves from the keyboard
- **WHEN** the active invocation receives Command-Option (or the Option-Shift alias) with Left, Right, Up, or Down
- **THEN** Jort moves the focused contextual boundary by the corresponding character or logical line, choosing start for Left/Up or end for Right/Down when no boundary has yet been focused
- **AND** ordinary Shift-arrow retains native text-selection behavior

#### Scenario: Context reaches another invocation
- **WHEN** pointer or keyboard expansion would overlap another active invocation-owned range
- **THEN** Jort stops at the nearest legal character boundary
- **AND** creates no overlapping or nested range

#### Scenario: Context spans both sides of its invocation
- **WHEN** contextual source exists before and after `/command`
- **THEN** Jort extracts the exact before and after characters concatenated in document order, excluding `/command`
- **AND** applies only the shared single-leading-U+0020 normalization before submission, preserving every other whitespace and newline character

### Requirement: Ephemeral input remains outside document semantics
Jort SHALL present ephemeral input in a focused single-line field or multiline text area anchored below and to the right of its canonical command token and SHALL exclude the prompt from canonical document semantics.

#### Scenario: Ephemeral prompt opens
- **WHEN** an ephemeral command is accepted
- **THEN** its prompt takes focus and remains anchored to the command as the document scrolls
- **AND** may naturally move offscreen with that anchor

#### Scenario: Ephemeral prompt is dismissed
- **WHEN** the focused prompt receives Escape, its X action is activated, or its command token becomes invalid
- **THEN** Jort closes the prompt and irreversibly discards its ephemeral content
- **AND** leaves the slash token as ordinary canonical text

#### Scenario: Document content is copied or persisted
- **WHEN** the user copies, saves, versions, closes, or recovers a document containing open ephemeral prompts
- **THEN** no ephemeral prompt content enters the copied text, revision, snapshot, persistence, or recovery payload

### Requirement: Execution is explicit and focus-owned
Jort SHALL submit an invocation only through its Run action or Shift-Return while its owned input, contextual wrapper, boundary, or ephemeral prompt is focused.

#### Scenario: Focused invocation runs
- **WHEN** the user activates Run or presses Shift-Return within invocation-owned focus
- **THEN** both inputs dispatch one identical validated execution path
- **AND** one activation cannot execute the invocation twice

#### Scenario: Submitted content begins with a space
- **WHEN** extracted contained, contextual, or ephemeral content begins with U+0020
- **THEN** Jort removes exactly that one leading space before validation and execution
- **AND** preserves all other spaces, tabs, newlines, Unicode scalars, and canonical document characters

#### Scenario: Return is used after acceptance
- **WHEN** completion is closed and the user presses Return inside canonical invocation input
- **THEN** the native editor inserts a newline
- **AND** Jort does not submit the invocation

#### Scenario: User edits outside an invocation
- **WHEN** focus is in unrelated document text and the user presses Shift-Return
- **THEN** Jort performs no tool action

#### Scenario: Several invocations share a line
- **WHEN** multiple nonoverlapping invocations exist or execute on one logical line
- **THEN** each retains independent focus, lifecycle, geometry, and controls
- **AND** an action affects only its owning invocation

### Requirement: Submission locks all source used by the invocation
Jort SHALL lock the command and contained input or the command and complete contextual source from successful submission until a terminal lifecycle action restores or removes that state.

#### Scenario: User selects locked text
- **WHEN** a selection includes submitted, processing, or error source, or the user attempts a non-deletion edit of pending text
- **THEN** Jort rejects the entire edit
- **AND** permits ordinary selection and copy across the same text

#### Scenario: User edits unrelated text
- **WHEN** an edit does not intersect any locked range
- **THEN** Jort applies the edit normally
- **AND** updates surviving invocation anchors without changing captured execution content

#### Scenario: User deletes pending text
- **WHEN** a deletion intersects some or all of one or more pending-merge calls and no processing or error lock
- **THEN** Jort asks for confirmation with “N mergeable responses will be deleted”, counting each affected call once
- **AND** confirmation deletes only the selected characters and removes all metadata for affected calls, leaving their unselected characters as ordinary text in one undoable transaction
- **AND** cancelling preserves both text and metadata

#### Scenario: Escape dismisses pending output
- **WHEN** the caret is within pending source or purple output and Escape is pressed with no completion open
- **THEN** Jort removes pending output and restores the editable tool prompt as Dismiss would

#### Scenario: Context is submitted
- **WHEN** a contextual invocation passes validation and begins execution
- **THEN** its whole contextual range becomes locked
- **AND** subsequent output continues to correspond to the captured immutable content

### Requirement: Every invocation follows one cancellable asynchronous lifecycle
Jort SHALL run fast and slow tools through inputting, submitted, processing, error or timeout, and pending-merge states with exactly one terminal transition per submitted generation.

#### Scenario: A fast tool completes
- **WHEN** a tool finishes before the configured processing-indicator delay
- **THEN** Jort advances directly to pending merge
- **AND** does not flash processing chrome

#### Scenario: Processing remains active
- **WHEN** execution exceeds the processing-indicator delay
- **THEN** Jort shows only a spinner and X Cancel action inside the green invocation region
- **AND** exposes the X as a named Cancel action to hover, keyboard, and accessibility clients

#### Scenario: User cancels processing
- **WHEN** the user activates Cancel before completion
- **THEN** Jort invalidates that execution generation and discards any late result
- **AND** removes invocation metadata while leaving invocation and canonical input as ordinary text

#### Scenario: Execution fails or times out
- **WHEN** a tool throws, violates its runtime boundary, or exceeds its timeout
- **THEN** Jort publishes no output, retains locked source, shows a readable error explanation with a red treatment, and exposes Dismiss only
- **AND** Dismiss restores the exact pre-submit editable invocation

#### Scenario: Validation fails
- **WHEN** submitted content fails manifest or tool validation before execution
- **THEN** Jort retains editable input and shows a readable explanation with an orange warning treatment
- **AND** makes no document mutation or history boundary

### Requirement: Tool decoration is connected, accessible, and layout stable
Jort SHALL draw contained and contextual source as one connected green range-union silhouette and pending canonical output as a connected purple region within the same compound structure without changing canonical text or gutter semantics.

#### Scenario: Input wraps or crosses logical lines
- **WHEN** an owned or contextual range spans visual fragments or canonical newlines
- **THEN** Jort removes shared internal edges and rounds only exposed outer corners of the fragment union
- **AND** does not render each fragment as an independent capsule
- **AND** clamps the wrapper to content extents rather than extending short logical lines to the editor's full width

#### Scenario: Pending output is published
- **WHEN** output begins immediately after an invocation or on a later fragment or line
- **THEN** the purple output joins the green source through a flush seam, shared edge, or short aligned neck
- **AND** remains visually associated with exactly that invocation

#### Scenario: Decorated content uses the gutter
- **WHEN** a connected wrapper crosses canonical and presentation-only rows
- **THEN** each canonical logical line retains its normal line number, wrapped and accessory rows receive blank gutter space, and no wrapper includes the gutter

#### Scenario: Pending actions are exposed
- **WHEN** output awaits Merge or Dismiss
- **THEN** Jort places a pull-request-style Merge icon and X Dismiss icon inside the purple region near the command token
- **AND** shows text labels on hover or focus and always exposes named accessible actions with adequate hit targets
- **AND** reserves presentation space so controls never overlap canonical text or contextual handles, with visible padding between source and output glyphs

#### Scenario: Run is available
- **WHEN** an invocation is editable
- **THEN** its Run button visibly displays the Shift-Enter shortcut as ⇧↵ and exposes a named Run action
- **AND** canonical input places that button close to the wrapper's right edge, while ephemeral input places it only in the prompt popover

#### Scenario: Action is hovered
- **WHEN** the pointer enters a Submit, Cancel, Merge, or Dismiss button
- **THEN** Jort shows a pointing-hand cursor and subtle hover background

#### Scenario: Pending state is restored by Undo
- **WHEN** Merge Undo replaces canonical text storage and restores pending metadata
- **THEN** Jort reapplies all control reservations and source/output styles before presenting the restored controls
- **AND** adjacent source and output wrappers use matching visual-line heights and vertical padding

#### Scenario: Command completion is displayed
- **WHEN** a slash query has matching enabled tools
- **THEN** a compact rounded opaque popover appears above editor glyphs, with commands left-aligned and muted tool names right-aligned
- **AND** the selected row uses background highlighting without a leading caret marker

#### Scenario: History compares tool state
- **WHEN** a revision contains an invocation or pending result, including a metadata-only transition
- **THEN** its affected diff rows expose a compact tool-command and lifecycle annotation
- **AND** comparison and copying retain the exact canonical text without adding annotation characters

#### Scenario: VoiceOver traverses an invocation
- **WHEN** VoiceOver reaches a decorated invocation
- **THEN** it encounters canonical text in document order plus separately named scope, Run, Cancel, Merge, Dismiss, warning, or error actions applicable to the current state
- **AND** the document accessibility value contains canonical text only

#### Scenario: Invocation scrolls or relayouts
- **WHEN** a connected invocation wraps, moves, expands above the viewport, or scrolls offscreen
- **THEN** viewport-bounded presentation geometry keeps visible text, gutter, handles, and controls aligned and recycles offscreen presentation views
- **AND** preserves the top visible stable line, relative offset, selection, and editor first responder when possible

### Requirement: Persisted invocation state degrades safely across recovery and package changes
Jort SHALL persist bounded canonical invocation lifecycle metadata atomically with canonical output and SHALL preserve canonical characters when metadata cannot be restored.

#### Scenario: Pending output is reopened
- **WHEN** a document with valid pending invocation metadata relaunches
- **THEN** Jort restores its connected source/output decoration, locks, actions, and captured package contract
- **AND** does not execute completed output again

#### Scenario: Metadata is missing or corrupt
- **WHEN** canonical invocation or output text exists without valid matching metadata
- **THEN** Jort drops the metadata and decorations
- **AND** preserves every canonical character as ordinary plain text

#### Scenario: Inputting state cannot map to a changed package
- **WHEN** bounded package-version migration cannot map an inputting invocation
- **THEN** contained mode retains `/tool` and input, contextual mode retains `/tool` and source, and ephemeral mode retains `/tool`
- **AND** all retained characters become ordinary text

#### Scenario: Completed state cannot map to a changed package
- **WHEN** bounded package-version migration cannot map an invocation with canonical output
- **THEN** Jort removes `/tool` and contained input where applicable while retaining output
- **AND** an empty completed output removes `/tool` and contained input and leaves no replacement
