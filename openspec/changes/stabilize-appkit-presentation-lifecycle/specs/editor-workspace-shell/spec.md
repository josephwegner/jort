## ADDED Requirements

### Requirement: App-owned windows share the dark product appearance
Jort SHALL apply its dark-only appearance at one application theme boundary before constructing ordinary app-owned windows and SHALL make document, Settings, popover, panel, and future app-owned surfaces inherit that policy consistently.

#### Scenario: Document and Settings windows open
- **WHEN** Jort presents its editor and Settings workspace in the same application session
- **THEN** both resolve the dark Aqua appearance from the shared application policy
- **AND** neither depends on an unrelated window having set appearance first

#### Scenario: Secondary surface opens
- **WHEN** Jort presents an app-owned completion popover, history/search workspace, prompt, or recovery surface
- **THEN** it inherits or deliberately applies the same theme policy where AppKit inheritance is unavailable
- **AND** does not introduce an accidental light appearance among dark product surfaces

### Requirement: Production interface copy has localizable ownership
Jort SHALL express app-owned user-visible labels, actions, accessibility names, status messages, warnings, and errors through stable localization resources or keys, with a complete base-language value and contextual guidance where meaning is ambiguous.

#### Scenario: Presentation code is split or moved
- **WHEN** an existing user-facing string moves into an extracted AppKit component
- **THEN** it retains the same base-language wording and stable localizable ownership
- **AND** is not replaced by a new untracked raw literal solely because of the refactor

#### Scenario: New product copy is introduced
- **WHEN** a later AppKit change adds an app-owned visible or accessibility string
- **THEN** the repository's localization check can discover its key and base-language value
- **AND** tests can resolve a useful fallback without depending on the developer's locale
