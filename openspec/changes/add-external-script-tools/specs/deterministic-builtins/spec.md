## MODIFIED Requirements

### Requirement: Tool scripts run without ambient authority
Jort SHALL evaluate `tool.js` inside a bounded JavaScript host that exposes only a deeply frozen invocation object, explicit captured host data, result construction, and cancellation observation, plus the mediated `jort.exec` message capability during explicitly submitted default-entry execution with current local per-tool permission and negotiated capability framing. Contract 2 scripts SHALL remain able to return inert typed action requests for independent app-side validation and execution without receiving a general I/O bridge. Exec SHALL follow external-script-execution and SHALL NOT add direct OS bindings to the JavaScript worker; external scripts themselves run with ordinary user permissions, not a separate containment boundary.

#### Scenario: Script begins execution
- **WHEN** a registered tool is submitted
- **THEN** its asynchronous entry point receives exactly one canonical or ephemeral `content` string plus explicitly injected captured clock, UUID, and cancellation facilities supported by the entry contract; contract 2 additionally receives separate validated arguments and bounded declared local calendar, entropy, and pure text-analysis data
- **AND** receives no mutable document or application object

#### Scenario: Script validates input before execution
- **WHEN** a package exports the optional asynchronous `validate` entry point
- **THEN** Jort invokes it with the same captured frozen input used by the main entry point before locking source or executing the tool
- **AND** a structured validation failure remains presentation-only and creates no document mutation or history boundary
- **AND** exec during validation and module initialization is denied without external dispatch

#### Scenario: Script requests ambient authority
- **WHEN** script code attempts direct network, filesystem, process, shell, application-state, native-bridge, plugin, dynamic-import, external-executable, package-discovery, or dynamic-evaluation access
- **THEN** the host denies that direct access
- **AND** manifest declarations alone cannot grant it

#### Scenario: Script uses permitted external capability
- **WHEN** an explicitly submitted JavaScript tool with current local permission calls `jort.exec` during default-entry execution over negotiated capability framing
- **THEN** the app-side host independently checks and dispatches the bounded request outside the JavaScript sandbox
- **AND** script stdout returns only as inert text to the calling tool, not as an automatically interpreted Jort action

#### Scenario: Legacy tools and model tools execute
- **WHEN** a legacy JavaScript tool does not use exec or a model tool is submitted
- **THEN** existing captured-input, contract adaptation, result, and action-validation behavior remains unchanged
- **AND** model tools receive no exec capability

#### Scenario: Script exceeds a resource bound
- **WHEN** script execution exceeds its wall-clock timeout, memory limit, cancellation boundary, or result cap
- **THEN** Jort terminates or invalidates its generation and returns one structured invocation-local failure
- **AND** publishes no partial canonical output

#### Scenario: Cancellation races with completion
- **WHEN** cancellation, timeout, and script completion race for one submission generation
- **THEN** exactly one terminal transition wins
- **AND** Jort ignores every late or duplicate result
