## ADDED Requirements

### Requirement: Installed package generations are bounded and explicitly indexed
Jort SHALL record one current generation and at most five previous successfully published valid generations for each active custom tool or bundled-tool override, and SHALL resolve only the current generation as executable.

#### Scenario: Tool is updated repeatedly
- **WHEN** an active tool has been successfully published more than six times under the bounded index schema
- **THEN** its index references the current generation and the five most recent previous generations in newest-first order
- **AND** no older generation remains part of the retained set

#### Scenario: Current generation is invalid
- **WHEN** the indexed current generation is missing, malformed, or fails validation and a previous retained generation is valid
- **THEN** Jort reports the current installed candidate as invalid and does not execute it
- **AND** does not silently execute or promote the previous generation

#### Scenario: Version-one index migrates
- **WHEN** Jort opens a valid version-one index that identifies only each tool's current generation
- **THEN** it migrates each proven current generation with an empty previous-generation list and durably publishes the new index
- **AND** does not classify unindexed legacy directories as successfully published history

### Requirement: Package and index publication is crash-consistent
Jort SHALL fully write, sync, reload, and validate a staged immutable package generation before publishing it under its final UUID name, SHALL durably publish the complete next index before changing in-memory authority, and SHALL garbage-collect obsolete data only afterward.

#### Scenario: Generation staging fails
- **WHEN** writing, syncing, reloading, validating, or renaming the staged generation fails
- **THEN** the prior index and current executable package remain authoritative
- **AND** no partial directory is referenced by the index

#### Scenario: Index publication fails
- **WHEN** a verified final generation exists but durable index publication fails
- **THEN** the prior index and package remain authoritative in memory and after relaunch
- **AND** the unreferenced generation is eligible for later trusted-index cleanup

#### Scenario: Garbage collection fails after publication
- **WHEN** the new index is durable and resolving the new current package succeeds but obsolete-file removal fails
- **THEN** the new package remains successfully published and executable
- **AND** Jort reports or records the cleanup problem and retries safe cleanup on a later save or reload

### Requirement: Registry cleanup is constrained by trusted durable state
Jort SHALL remove abandoned staging directories and unreferenced UUID generation directories only after successfully decoding, validating, and, when needed, durably migrating the installed index.

#### Scenario: Valid index loads with orphaned directories
- **WHEN** direct children of the installed tools directory include exact registry staging names or UUID generation directories absent from the complete index reference set
- **THEN** Jort removes those unreferenced directories without following links
- **AND** preserves every indexed current and previous generation

#### Scenario: Index cannot be trusted
- **WHEN** the installed index is corrupt, future-versioned, invalid, or cannot complete migration
- **THEN** Jort performs no destructive generation or staging cleanup
- **AND** preserves candidate files while exposing the registry failure

#### Scenario: Unexpected filesystem entry is present
- **WHEN** the installed tools directory contains a symbolic link, special file, nested link, or child whose name is neither an exact staging name nor a UUID generation
- **THEN** registry garbage collection does not follow or remove that entry
- **AND** never deletes outside the installed tools directory

### Requirement: Deletion publishes catalog removal before reclaiming generations
Jort SHALL durably remove a custom tool or bundled-tool override from the index before reclaiming any of its current or previous package generations.

#### Scenario: Custom tool deletion succeeds
- **WHEN** the user confirms deletion and the new index is durably published
- **THEN** the tool is absent from the executable catalog before its retained generation directories are removed
- **AND** any cleanup interrupted by a crash is completed as unreferenced cleanup on a later trusted reload

#### Scenario: Bundled override is restored
- **WHEN** the user restores a bundled definition and the override-removing index is durably published
- **THEN** the immutable bundled package becomes authoritative before override generations are reclaimed
- **AND** interruption cannot leave the index pointing to a deleted override generation

#### Scenario: Index removal fails
- **WHEN** durable index publication fails during deletion or restoration
- **THEN** the prior installed package and every referenced generation remain intact and authoritative
- **AND** no generation is reclaimed for that attempted operation
