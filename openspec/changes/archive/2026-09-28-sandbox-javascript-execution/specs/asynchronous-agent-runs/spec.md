## ADDED Requirements

### Requirement: Model authority never enters JavaScript containment
Jort SHALL keep OpenRouter credential lookup, HTTP transport, model request construction, and provider response handling in the separately composed model Runtime path and SHALL send none of those capabilities or values to the JavaScript broker or worker.

#### Scenario: Model tool executes while JavaScript containment is installed
- **WHEN** the shared lifecycle dispatches a model-backed package
- **THEN** Runtime uses the existing lazy model provider and bounded model request directly without spawning a JavaScript worker
- **AND** returns its result through the same high-level contract and reducer actions

#### Scenario: JavaScript worker is compromised
- **WHEN** native code in the disposable worker attempts to discover OpenRouter state or credentials
- **THEN** it has no credential value, provider object, Keychain access group, settings path, or network entitlement
- **AND** model execution and cached connection state remain outside the worker process
