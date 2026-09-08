## ADDED Requirements

### Requirement: Search stays in the document window
Command-F and Search Document SHALL open a floating search overlay at the top-right of the editor, preserving window geometry and document context.

#### Scenario: Open and expand search
- **WHEN** the user opens search with no query
- **THEN** only the search field and close button are shown
- **WHEN** the user types a query
- **THEN** the overlay expands downward to display result count, options, matching line context, and previous/next match buttons

#### Scenario: Navigate and dismiss
- **WHEN** the user clicks a result or a previous/next arrow
- **THEN** the editor scrolls to and selects the exact current match while search remains open
- **WHEN** the user presses Escape or clicks the close button
- **THEN** search closes and focus returns to the editor

### Requirement: Users can search the current document from the palette
Jort SHALL provide a Search Document action that searches an immutable snapshot of the current in-memory canonical text and presents matching current-document ranges with bounded context.

#### Scenario: Query has matches
- **WHEN** the user enters a nonempty query
- **THEN** Jort asynchronously returns matches in document order with line ordinal and bounded context from the matching logical line, without newline glyphs
- **AND** searching does not mutate text or block editor input

#### Scenario: Query is superseded
- **WHEN** the user changes the query before a prior scan finishes
- **THEN** Jort cancels or discards the prior scan and displays results only for the newest query

#### Scenario: Search options change
- **WHEN** the user toggles case-sensitive or whole-word matching
- **THEN** Jort recomputes results using those explicit options

### Requirement: Search navigation never selects unrelated stale text
Jort SHALL associate each result with the searched generation, logical-line identity, line-relative UTF-16 range, and matched-text hash and SHALL revalidate it before navigation.

#### Scenario: Result remains valid
- **WHEN** the user activates a result whose anchor and matched text still resolve
- **THEN** Jort selects the exact match, scrolls it into view, and focuses the editor

#### Scenario: Document changed after search
- **WHEN** the selected result no longer resolves to the same matched text
- **THEN** Jort refreshes or removes the stale result
- **AND** does not select a coincidental range in unrelated text

### Requirement: Search is lazy, local, and performance bounded
Jort SHALL initialize search only after explicit use, SHALL perform scanning off the main actor, and SHALL not create a persistent index unless a later measured and specified change introduces one.

#### Scenario: App launches
- **WHEN** Jort starts and Search Document is not invoked
- **THEN** no search scan or index maintenance runs

#### Scenario: Large document is searched
- **WHEN** a query scans `CrawlLargeDocument`
- **THEN** the editor remains within its typing and scrolling budgets
- **AND** initial useful results appear within 200 ms at the 95th percentile on the normative hardware baseline

### Requirement: Search results are keyboard and accessibility operable
Jort SHALL expose the search query, options, result count, line context, selection, and navigation actions to Full Keyboard Access and VoiceOver.

#### Scenario: Keyboard user searches and navigates
- **WHEN** a keyboard user opens Search Document, enters a query, selects a result, and presses Return
- **THEN** the exact current match is selected in the editor
- **AND** focus returns to the document while the search overlay remains open
