# Landmarks Specification

## ADDED Requirements

### Requirement: Emoji landmarks replace line numbers
Jort SHALL display a narrow logical-line gutter whose default entry is the line number and SHALL allow the user to replace an entry with any emoji using the macOS emoji picker.

#### Scenario: Add landmark
- **WHEN** the user clicks a line number and chooses an emoji
- **THEN** Jort creates a landmark anchored to that logical line's paragraph identity
- **AND** the gutter displays the emoji instead of the line number
- **AND** the emoji is not inserted into canonical text

#### Scenario: Clear landmark
- **WHEN** the user clears a landmark
- **THEN** Jort removes its organizational metadata
- **AND** the gutter displays the line number again

### Requirement: Paragraph anchoring
Jort SHALL keep a landmark attached to its paragraph through edits above it and SHALL treat it as one movable anchor rather than the start of a proprietary block.

#### Scenario: Insert above landmark
- **WHEN** text is inserted above a landmark
- **THEN** the landmark moves with its anchored paragraph

#### Scenario: Move landmark
- **WHEN** the user moves a landmark to a different paragraph
- **THEN** only the landmark moves
- **AND** following lines retain ordinary text semantics

#### Scenario: Edit ambiguity
- **WHEN** split, join, paste, undo, or IME composition makes an anchor ambiguous
- **THEN** Jort applies documented deterministic anchoring rules
- **AND** never silently attaches the landmark to unrelated content

### Requirement: Landmark navigation mode
Jort SHALL provide a small bullet-list control in the top of the gutter that toggles between line-number mode and landmark navigation mode.

#### Scenario: Open landmark navigation
- **WHEN** the user activates the landmark control
- **THEN** the landmark list replaces the line-number entries within the same gutter width
- **AND** the editor canvas does not shift horizontally

#### Scenario: Landmark list layout
- **WHEN** landmark navigation mode is active
- **THEN** landmark emoji appear in document order
- **AND** are stacked from the top with approximately one editor line of vertical spacing
- **AND** no non-emoji placeholder is shown for an unlandmarked line

#### Scenario: Navigate
- **WHEN** the user activates an emoji in landmark navigation mode
- **THEN** the editor scrolls to its anchored paragraph
- **AND** focuses the document without changing its text

### Requirement: Stable internal identity with emoji-facing language
Jort SHALL use stable landmark identities internally while expressing routing and configuration in user-visible emoji language.

#### Scenario: Duplicate emoji
- **WHEN** multiple landmarks use the same emoji
- **THEN** each retains a distinct internal identity
- **AND** an existing configured connection remains attached to its intended identity

#### Scenario: Change emoji
- **WHEN** the emoji for a connection destination changes
- **THEN** the connection remains attached to the same landmark identity

