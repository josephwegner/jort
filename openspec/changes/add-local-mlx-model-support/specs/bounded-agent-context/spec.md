## MODIFIED Requirements

### Requirement: Model selection uses a bundled curated catalog
Jort SHALL bundle a bounded curated model catalog containing explicit backend metadata and SHALL persist model selections by stable provider-aware identifier without fetching the catalog during Settings use. Existing OpenRouter identifiers SHALL remain valid and unchanged, and the local Qwen entry SHALL use a distinct stable identity mapped to its pinned assets.

#### Scenario: User opens the model picker
- **WHEN** a model-backed tool's model field is activated
- **THEN** Jort presents a compact filterable list with friendly model names and restrained provider or family metadata, explicitly distinguishing local from cloud execution
- **AND** performs no network request or model load

#### Scenario: User filters models
- **WHEN** the user enters a model query
- **THEN** Jort filters the bundled catalog by visible name and supported metadata while keeping keyboard selection and accessibility available
- **AND** stores the selected stable catalog identifier rather than its display label

#### Scenario: User is not connected to OpenRouter
- **WHEN** the user creates or edits a model-backed tool while disconnected
- **THEN** the complete bundled model catalog remains available for selection
- **AND** saving valid tool configuration does not begin authentication, download assets, or require the selected model to be ready

#### Scenario: Selected model leaves the bundled catalog
- **WHEN** an application update no longer contains a definition's selected model identifier
- **THEN** Jort preserves the stored identifier and marks the tool unavailable with an actionable diagnostic
- **AND** does not silently select or execute another model

#### Scenario: Existing cloud configuration is loaded after upgrade
- **WHEN** Jort loads an existing saved cloud model selection or bundled ask/rewrite template
- **THEN** its selected cloud identity and default behavior remain unchanged
- **AND** selecting Qwen requires an explicit saved tool edit or customization through the existing Tools Settings workflow, not an invocation-level override

### Requirement: Disconnected model tools remain discoverable
Jort SHALL keep valid enabled model-backed tools in slash-command completion regardless of provider readiness and SHALL gate execution on readiness of the selected model rather than a global OpenRouter connection.

#### Scenario: Disconnected user opens completion
- **WHEN** OpenRouter is disconnected and the user types a matching slash query
- **THEN** configured model-backed tools appear with ordinary tool completion behavior
- **AND** no authentication, download, or provider initialization occurs

#### Scenario: Disconnected user attempts a cloud Run
- **WHEN** the user submits a cloud model-backed invocation without an available OpenRouter credential
- **THEN** Jort keeps the invocation editable and presents an actionable validation warning directing the user to Models Settings
- **AND** does not lock source, initialize a model request, or mutate canonical output

#### Scenario: Disconnected user attempts a ready local Run
- **WHEN** the user submits a local model-backed invocation on supported hardware with a verified installation while OpenRouter is disconnected
- **THEN** Jort allows ordinary execution without cloud authentication
- **AND** captures the saved local model identity for that generation

#### Scenario: Local model is not ready
- **WHEN** a submitted local tool lacks supported capability or a verified model installation
- **THEN** Jort keeps the invocation editable and presents an actionable local readiness warning directing the user to Models Settings
- **AND** does not lock source, begin a download/load, mutate canonical output, or substitute a cloud model
