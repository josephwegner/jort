# External Capture Specification

## ADDED Requirements

### Requirement: Relay inbox does not become canonical storage
Jort SHALL accept optional webhook/Pebble payloads through a minimal authenticated relay that retains unacknowledged items only for a defined retention period.

#### Scenario: App offline
- **WHEN** a capture arrives while the Mac app is offline
- **THEN** the relay retains it as an unacknowledged inbox item
- **AND** does not modify the local document

#### Scenario: Acknowledgement
- **WHEN** the local app durably commits or explicitly rejects a delivered capture
- **THEN** it sends an authenticated acknowledgement
- **AND** the relay applies the configured deletion/retention policy

### Requirement: Emoji-visible destination routing
Jort SHALL let the user configure a connection using a visible emoji landmark while retaining stable internal identity for routing.

#### Scenario: Destination present
- **WHEN** a capture is delivered and its destination landmark exists
- **THEN** Jort routes the capture to that landmark's configured insertion policy
- **AND** commits it atomically with provenance metadata

#### Scenario: Duplicate emoji
- **WHEN** another landmark uses the same emoji
- **THEN** Jort uses the configured stable identity
- **AND** does not guess from the emoji alone

### Requirement: Deterministic capture placement
Jort SHALL use chronological append after a deterministic capture section when its boundary can be established; otherwise V1 SHALL insert immediately below the destination anchor.

#### Scenario: Deterministic section
- **WHEN** the next landmark or explicit structure defines the destination section boundary unambiguously
- **THEN** Jort appends captures chronologically within that section

#### Scenario: Fuzzy boundary
- **WHEN** the destination section boundary is ambiguous
- **THEN** Jort prepends the capture immediately below the anchor
- **AND** does not infer a fuzzy multi-line block

### Requirement: Missing destinations queue outside the document
Jort SHALL keep captures outside canonical text when their configured destination is missing, unavailable, or unresolved.

#### Scenario: Destination deleted
- **WHEN** a destination landmark is deleted before capture routing
- **THEN** the capture remains queued
- **AND** Jort does not choose a different matching emoji or insert at the document top or bottom

#### Scenario: Resolve queue
- **WHEN** the user restores the destination or chooses another landmark
- **THEN** Jort commits the queued items in source order as one transaction
- **AND** preserves capture provenance

### Requirement: Capture notifications are unobtrusive
Jort SHALL expose waiting captures as notifications adjacent to the Jort title and SHALL keep the editor free of a permanent queue panel.

#### Scenario: Open notifications
- **WHEN** the user activates the notification indicator
- **THEN** Jort shows recent capture and run notifications in a transient drawer
- **AND** queued items expose explicit Insert, reroute, or keep-queued actions as appropriate

#### Scenario: Capture poll failure
- **WHEN** capture polling or a capture plugin fails
- **THEN** existing local decoration remains renderable
- **AND** typing and local document operations are unaffected

