## ADDED Requirements

### Requirement: JavaScript Runtime composition terminates at a broker client
After containment, `JortToolRuntime` SHALL implement JavaScript validation/execution as a lazy bounded broker client, SHALL keep engine/process/protocol details behind the existing Contracts protocols, and SHALL compose model and JavaScript executors as separate concrete paths at the application boundary.

#### Scenario: Application composes JavaScript execution
- **WHEN** the editor workspace receives its JavaScript validator and executor
- **THEN** the application injects a Runtime broker client conforming to the same bounded contract used by tests/fakes
- **AND** no Settings, AppKit, Document, Contracts, or application source imports the engine shim

#### Scenario: Broker is unavailable
- **WHEN** Runtime cannot authenticate, connect to, or obtain a valid response from the broker
- **THEN** it returns one typed infrastructure failure through the existing executor contract
- **AND** does not fall back to loading or executing QuickJS in the main process

#### Scenario: Model executor is composed
- **WHEN** a configured model tool executes
- **THEN** Runtime uses the separately injected model/provider path without contacting the JavaScript broker
- **AND** both paths converge only on bounded contract results and lifecycle actions
