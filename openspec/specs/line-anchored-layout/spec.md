# line-anchored-layout Specification

## Purpose
Define presentation-only line accessories and the shared visible geometry that lays them out in Jort's editor.

## Requirements

### Requirement: Presentation accessories expand an anchor line rather than create fake lines
Jort SHALL provide an AppKit presentation layout in which a bounded transient accessory is anchored by stable `LineID`, expands only that logical line's vertical band, and contributes no canonical characters or logical-line metadata.

#### Scenario: No accessory is registered
- **WHEN** the document has no line accessory descriptors
- **THEN** text, line heights, wrapping, gutter positions, scrolling, and selection geometry match the ordinary editor layout

#### Scenario: Accessory is registered for a visible line
- **WHEN** a valid bounded accessory descriptor is registered for a current `LineID`
- **THEN** Jort places presentation-only space after that line's final visual text fragment
- **AND** positions the accessory inside the expanded band owned by that line
- **AND** shifts subsequent visible lines by the reserved height without inserting text

#### Scenario: Anchor line wraps
- **WHEN** the anchor line wraps across multiple visual fragments
- **THEN** all wrapped fragments remain one logical line
- **AND** its accessory begins after the final wrapped fragment

#### Scenario: Anchor disappears
- **WHEN** an edit removes the accessory's anchor `LineID`
- **THEN** Jort removes the transient descriptor and collapses its reserved space
- **AND** does not move the accessory to an unrelated neighboring line

### Requirement: Canonical content alone determines line numbers
Jort SHALL assign gutter ordinals only to canonical logical lines and SHALL align each ordinal or landmark with its line's expanded presentation band regardless of accessory content.

#### Scenario: Accessories separate consecutive content lines
- **WHEN** an accessory expands canonical line 5 and canonical content continues below it
- **THEN** the next canonical lines are numbered 6 and 7
- **AND** no accessory title, explanatory row, or control receives a line number

#### Scenario: Controls follow a later content line
- **WHEN** a second accessory containing actions is anchored to canonical line 7
- **THEN** line 7's band expands to contain those actions
- **AND** the actions remain associated with line 7 without becoming line 8

#### Scenario: A landmarked anchor expands
- **WHEN** an accessory is anchored to a landmarked line
- **THEN** its emoji remains aligned to the anchor line's text origin in normal gutter mode
- **AND** landmark index ordering and navigation continue to use canonical document order

### Requirement: One visible geometry source coordinates line-local UI
Jort SHALL derive visible line bands, ruler labels and hit targets, accessory frames, scroll destinations, and viewport restoration from one presentation geometry source using only visible TextKit layout plus bounded overscan.

#### Scenario: Expanded lines scroll through the viewport
- **WHEN** the user scrolls a document containing expanded line bands
- **THEN** gutter labels, landmark hit targets, text, and accessories remain aligned
- **AND** layout work stays bounded to the viewport and indexed visible descriptors

#### Scenario: Relayout occurs above the viewport
- **WHEN** an accessory above the viewport expands or collapses
- **THEN** Jort preserves the top visible stable line and its relative vertical offset when that line survives
- **AND** preserves the current selection and editor first responder

#### Scenario: User navigates to an expanded line
- **WHEN** Pocket or the landmark index navigates to an anchor with an expanded band
- **THEN** Jort scrolls the canonical line text into view and places an ordinary text selection there
- **AND** does not focus or activate the accessory implicitly

### Requirement: Presentation accessories remain outside document semantics
Jort SHALL keep transient accessory descriptors and views out of snapshots, persistence, copy, native Find, text undo, and the document text area's accessibility value.

#### Scenario: Document behavior is used around an accessory
- **WHEN** the user copies, searches, edits, undoes, saves, or relaunches around a line with a transient accessory
- **THEN** those operations act on canonical text and existing document metadata only
- **AND** the accessory contributes no saved payload, searchable characters, or independent text undo step

#### Scenario: Accessibility traverses an expanded band
- **WHEN** an accessibility client navigates an anchor line with an accessory
- **THEN** it encounters the canonical line text before the separately labeled accessory and then the next canonical line
- **AND** the text area's value and reported line content exclude accessory labels and controls

### Requirement: This change exposes no product widget
Jort SHALL exercise line expansion through internal or test fixtures only until a later feature defines the accessory's product data, lifecycle, actions, and persistence.

#### Scenario: User opens the shipped healthy editor
- **WHEN** no later Run feature supplies an accessory descriptor
- **THEN** no result card, widget title, explanatory result, Merge, Dismiss, capture queue, or Ask Jort control is visible
- **AND** the shell incurs no empty vertical reservation for future widgets
