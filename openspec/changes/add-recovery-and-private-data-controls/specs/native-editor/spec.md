## ADDED Requirements

### Requirement: Recovery and private-data actions remain quiet and accessible
Jort SHALL place Save/Retry Save, Save Recovery Copy, Clear History and Recovery Data, and applicable Retry Cleanup actions in the File menu or contextual storage-health UI, SHALL keep them out of Pocket, and SHALL expose their state and confirmation to keyboard and accessibility clients without stealing editor focus for routine status changes.

#### Scenario: File menu opens for a dirty healthy document
- **WHEN** the active editor has a verified loaded store and an unsaved authoritative revision
- **THEN** File presents enabled Save with Command-S and Save Recovery Copy
- **AND** Pocket contains neither recovery nor purge actions

#### Scenario: File menu opens after automatic retries are exhausted
- **WHEN** the active editor requires manual persistence retry
- **THEN** the Command-S item is titled Retry Save and describes the newest pending revision through accessible state
- **AND** activating it invokes the explicit retry path rather than waiting for autosave

#### Scenario: Recovery needs attention at launch
- **WHEN** recovery succeeds from a damaged store or all bounded candidates are rejected
- **THEN** Jort presents concise localized nonmodal or launch-context UI explaining what was preserved and which actions remain available
- **AND** keeps recovery editing, copy, selection, and recovery export usable without silently replacing the source

#### Scenario: User saves a recovery copy while source is unhealthy
- **WHEN** the user chooses Save Recovery Copy and completes the native save panel
- **THEN** Jort exports the newest coherent in-memory snapshot to the chosen versioned JSON file and reports the actual result
- **AND** does not overwrite, import, or mark the canonical source healthy

#### Scenario: User confirms destructive purge
- **WHEN** Clear History and Recovery Data is available and activated
- **THEN** a keyboard- and VoiceOver-operable confirmation names history, milestones, recovery data, diagnostic backups, current-document preservation, and deletion limits
- **AND** cancellation changes no persistence, history, or recovery data

#### Scenario: Purge cleanup is incomplete
- **WHEN** the current-only store is active but recognized old managed copies remain
- **THEN** Jort reports that cleanup is incomplete and offers Retry Cleanup without claiming deletion succeeded
- **AND** the editor remains usable with its current text, selection, and focus
