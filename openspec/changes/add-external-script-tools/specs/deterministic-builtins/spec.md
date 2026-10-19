## MODIFIED Requirements

### Requirement: Tool scripts run without ambient authority
Jort SHALL evaluate `tool.js` inside a bounded JavaScript host that exposes only a deeply frozen invocation object, explicit captured host data, result construction, and cancellation observation, plus the narrowly scoped `jort.exec` message capability only for opted-in external-capable tools during explicit default-entry execution under protocol version three. Contract 2 scripts SHALL remain able to return inert typed action requests for independent app-side validation and execution without receiving a general I/O bridge. Exec SHALL require independent local approval and separate sandboxed external execution as specified by external-script-execution; it SHALL NOT confer ambient OS authority on the JavaScript worker.

#### Scenario: Script begins execution
- **WHEN** a registered tool is submitted
- **THEN** its asynchronous entry point receives exactly one canonical or ephemeral `content` string plus explicitly injected captured clock, UUID, and cancellation facilities supported by the entry contract; contract 2 additionally receives separate validated arguments and bounded declared local calendar, entropy, and pure text-analysis data
- **AND** receives no mutable document or application object

#### Scenario: Script validates input before execution
- **WHEN** a package exports the optional asynchronous `validate` entry point
- **THEN** Jort invokes it with the same captured frozen input used by the main entry point before locking source or executing the tool
- **AND** a structured validation failure remains presentation-only and creates no document mutation or history boundary
- **AND** exec is denied during validation and module initialization without external dispatch

#### Scenario: Script requests ambient authority
- **WHEN** script code attempts direct network, filesystem, process, shell, application-state, native-bridge, plugin, dynamic-import, external-executable, package-discovery, or dynamic-evaluation access
- **THEN** the host denies that access
- **AND** manifest declarations alone cannot grant it

#### Scenario: Script uses approved external capability
- **WHEN** an opted-in tool explicitly submitted by the user calls `jort.exec` during default-entry execution with a valid current local binding and protocol version three
- **THEN** the host independently authorizes a bounded message request to the separate sandboxed external supervisor
- **AND** existing contract-one/two tools without opt-in, unapproved calls, validation, and initialization remain unable to invoke external executables

#### Scenario: Script exceeds a resource bound
- **WHEN** script execution exceeds its wall-clock timeout, memory limit, cancellation boundary, or result cap
- **THEN** Jort terminates or invalidates its generation and returns one structured invocation-local failure
- **AND** publishes no partial canonical output

#### Scenario: Cancellation races with completion
- **WHEN** cancellation, timeout, and script completion race for one submission generation
- **THEN** exactly one terminal transition wins
- **AND** Jort ignores every late or duplicate result
