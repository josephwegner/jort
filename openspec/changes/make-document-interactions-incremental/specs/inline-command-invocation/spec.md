## ADDED Requirements

### Requirement: Tool-generated document changes use atomic incremental patches
Jort SHALL apply publication, Merge, Dismiss, and restoration intent as one document-owned patch containing bounded text replacements, annotation operations, and explicit revision, anchor, hash, lifecycle-generation, and package-generation preconditions, and SHALL NOT construct a temporary coordinator or accept a prebuilt replacement snapshot as trusted mutation input.

#### Scenario: Tool output publishes
- **WHEN** the active headless lifecycle authorizes complete bounded output for a current generation
- **THEN** document integration submits one patch through the authoritative coordinator's incremental primitives
- **AND** canonical text and invocation metadata commit together in one new revision or remain wholly unchanged

#### Scenario: Tool mutation precondition is stale
- **WHEN** the base revision, source anchor/hash, lifecycle generation, package generation, or locked range no longer matches
- **THEN** the coordinator rejects the patch before publishing any text or annotation change
- **AND** returns the typed rejection to the headless lifecycle for deterministic reconciliation

#### Scenario: Tool edit affects a bounded region in a large document
- **WHEN** publication or Merge replaces a bounded invocation/source range
- **THEN** its text and line work follows the same affected-region and logarithmic-index bounds as an equivalent native transaction
- **AND** it does not validate or rebuild the complete document solely because the mutation originated from a tool
