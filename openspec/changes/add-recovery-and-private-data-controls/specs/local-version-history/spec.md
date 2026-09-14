## ADDED Requirements

### Requirement: Confirmed private-data purge removes every retained revision
Jort SHALL treat Clear History and Recovery Data as an explicit exception to ordinary history retention and SHALL remove all pre-boundary history rows, including minimum-recent revisions, restore milestones, unavailable/corrupt entries, and pending history work, while preserving the purge-boundary current document outside history.

#### Scenario: History contains protected milestones
- **WHEN** the user confirms a private-data purge for a verified loaded document
- **THEN** the fresh replacement contains no retained revision or milestone from before the boundary
- **AND** ordinary pruning continues to protect milestones whenever a purge is not explicitly confirmed

#### Scenario: History retention is pending
- **WHEN** a scheduled idle, semantic, retry, or before-restore revision has not published when the purge boundary is captured
- **THEN** Jort cancels or drains it so it cannot write into the old or replacement store as pre-boundary history
- **AND** post-boundary edits may begin a new ordinary history timeline only after purge cleanup completes

#### Scenario: History opens after purge
- **WHEN** the user opens Version History after successful purge and before any new history boundary
- **THEN** no pre-boundary revision is available to browse, compare, or restore
- **AND** any newly established current baseline contains only the preserved boundary or later document state

#### Scenario: Purge fails before replacement
- **WHEN** a current-only replacement cannot be made authoritative
- **THEN** Jort does not claim history deletion and the original history remains associated with the original valid store
- **AND** the user can retry after resolving the reported failure
