## MODIFIED Requirements

### Requirement: Every tool uses one declarative JavaScript package format
Jort SHALL define each tool as a package containing a schema-valid `tool.json` manifest and exactly one declared executor: JavaScript using `tool.js`, or model using bounded `instructions.txt` and a bundled model identifier. Jort SHALL use the same registry and invocation lifecycle for both executors, and SHALL decode legacy definitions without an executor as JavaScript.

#### Scenario: A package manifest is loaded
- **WHEN** Jort discovers a candidate tool package
- **THEN** it validates the manifest's stable reverse-DNS-style ID, positive integer version, display name, slash command, description, executor and entry contract version, input mode, output operation, and byte and line caps
- **AND** does not evaluate `tool.js` merely to discover or display the package

#### Scenario: A valid package is enabled
- **WHEN** the manifest and executor-specific implementation satisfy the supported package contract
- **THEN** Jort registers its command, metadata, validation, and asynchronous entry point through the shared registry
- **AND** makes no distinction between bundled and installed execution privileges

#### Scenario: A package is malformed or conflicting
- **WHEN** a manifest, implementation, stable ID, or slash command is invalid or conflicts with another package at the same precedence
- **THEN** Jort disables only the affected package and reports a bounded diagnostic
- **AND** continues discovering and running unrelated valid packages

