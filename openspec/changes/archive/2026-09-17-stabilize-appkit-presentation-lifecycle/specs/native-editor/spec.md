## ADDED Requirements

### Requirement: Presentation updates preserve native editing continuity
Jort SHALL reconcile editor, ruler, and overlay presentation without interrupting native text input, marked-text composition, selection, first responder, undo grouping, immediate startup editing, or canonical transaction ownership.

#### Scenario: User types while presentation is dirty
- **WHEN** a content, layout, or lifecycle update is scheduled while the editor is accepting native input
- **THEN** committed characters and selection update through the ordinary native transaction path without waiting for presentation reconciliation
- **AND** the later presentation pass does not create another canonical edit or undo group

#### Scenario: Marked text overlaps a pending presentation update
- **WHEN** reconciliation would style, mount, or move presentation associated with the active marked-text range
- **THEN** Jort defers the composition-disturbing portion until marked text commits or is cancelled
- **AND** preserves candidate interaction and the startup-load deferral contract

#### Scenario: Persistence state changes during paint
- **WHEN** storage or startup state changes while AppKit is displaying the editor
- **THEN** its typed projection invalidates presentation outside drawing
- **AND** drawing cannot advance startup state, retry persistence, replace document state, or move focus

### Requirement: Editor presentation decomposition preserves one document owner
Splitting native views and presentation coordinators SHALL NOT create another mutable document model; all accepted canonical edits SHALL continue through `DocumentCoordinator` transactions and all presentation components SHALL consume immutable projections.

#### Scenario: Extracted text view accepts an edit
- **WHEN** the native text view commits a character, paste, service replacement, deletion, or composition
- **THEN** it forwards one typed native transaction through the editor adapter
- **AND** no ruler, styling, overlay, or persistence-projection component mutates canonical text independently

#### Scenario: Programmatic presentation changes
- **WHEN** invocation styles, gutter controls, storage notices, or workspace overlays reconcile
- **THEN** they update presentation-only state through their narrow owners
- **AND** the document revision remains unchanged unless an explicit document transaction effect is separately accepted
