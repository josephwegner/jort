## ADDED Requirements

### Requirement: Startup editing is immediate and lossless
Jort SHALL make its native text view focused, selectable, and editable as soon as the editor shell is ready, SHALL preserve accepted text entered while persistence is loading, and SHALL reconcile that text with the authoritative load result without replacing an existing stored document.

#### Scenario: User types while a stored document is loading
- **WHEN** the editor shell becomes interactive before persistence returns a verified stored snapshot and the user enters text
- **THEN** the accepted startup text appears immediately through the normal native editing path
- **AND** Jort does not treat editability as evidence that persistence loading completed

#### Scenario: Load succeeds after startup text is entered
- **WHEN** persistence returns a verified nonempty stored snapshot after the user has entered accepted startup text
- **THEN** Jort presents the startup text above the complete stored text in one reconciled document
- **AND** preserves the stored document identity, revision lineage, and unaffected metadata rather than saving the placeholder document over it

#### Scenario: Merge needs a text boundary
- **WHEN** startup text and stored text are both nonempty, the startup text does not end in a supported newline, and the stored text does not begin with a supported newline
- **THEN** Jort inserts one LF newline between them
- **AND** otherwise preserves both texts and their existing newline sequences exactly

#### Scenario: Either side already supplies a boundary
- **WHEN** startup text ends in a supported newline or stored text begins with a supported newline
- **THEN** Jort concatenates them without adding another newline
- **AND** does not normalize LF, CRLF, CR, NEL, line-separator, or paragraph-separator content

#### Scenario: Load succeeds without startup content
- **WHEN** persistence returns a verified stored snapshot and the startup draft contains no accepted text
- **THEN** Jort presents the stored snapshot without creating a startup transaction
- **AND** the editor remains first responder unless the user intentionally moved focus

#### Scenario: Startup selection survives reconciliation
- **WHEN** load succeeds while the user has a selection or insertion point within accepted startup text
- **THEN** the reconciled document preserves that UTF-16 selection within the startup prefix when valid
- **AND** loading does not move focus into the stored content

#### Scenario: User undoes after successful reconciliation
- **WHEN** the user invokes Undo after startup text has been merged with the loaded document
- **THEN** one undo group removes the startup text and any generated boundary while leaving the loaded document intact
- **AND** Redo restores the same merged result without restoring a placeholder document identity

#### Scenario: Load resolves during marked-text composition
- **WHEN** persistence succeeds while the native text view has uncommitted marked text
- **THEN** Jort leaves the composition and candidate interaction intact until it commits or is cancelled
- **AND** includes only committed composition text in the startup merge

#### Scenario: Load fails after startup editing
- **WHEN** persistence cannot open or recover the source store after the user has entered startup text
- **THEN** Jort keeps the current in-memory text editable with its native selection and undo behavior
- **AND** exposes a recovery-editing state without overwriting or replacing the failed source files

### Requirement: Editor load completion is explicitly observable
Jort SHALL expose a typed editor startup phase that distinguishes loading, loaded-and-ready, and editable recovery after failure, and tests and UI coordination SHALL use that phase rather than native control properties as a proxy for persistence state.

#### Scenario: Test waits for ordinary load
- **WHEN** a native editor test requires a loaded document before acting
- **THEN** it waits until the editor startup phase reports ready
- **AND** cannot pass its load precondition merely because `NSTextView.isEditable` is true

#### Scenario: Test exercises the startup window
- **WHEN** a controlled persistence fixture delays load completion
- **THEN** the test can observe the loading phase while the editor remains editable
- **AND** can deterministically resolve the load as success, failure, or future-version refusal
