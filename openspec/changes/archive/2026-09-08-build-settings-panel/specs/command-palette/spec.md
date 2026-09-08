## ADDED Requirements

### Requirement: Pocket can open Settings
Jort SHALL register an Open Settings action in Pocket and SHALL route it to the same single-instance Settings presenter used by the application menu and Command-comma.

#### Scenario: Settings opens from Pocket
- **WHEN** the user selects Open Settings in Pocket
- **THEN** Pocket dismisses and the existing or newly presented Settings window becomes key
- **AND** the document selection and viewport remain unchanged

#### Scenario: Settings is already open from Pocket
- **WHEN** the user chooses Open Settings while the Settings window already exists
- **THEN** Jort activates that window without creating a duplicate or resetting its selected pane or draft
- **AND** focus moves to the Settings window's current appropriate control
