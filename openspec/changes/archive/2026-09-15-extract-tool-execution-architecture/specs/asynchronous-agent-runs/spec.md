## ADDED Requirements

### Requirement: Model execution is composed behind the shared runtime boundary
Jort SHALL construct provider-specific model transports lazily outside Settings and AppKit, SHALL supply credentials through a narrow injected interface only when required, and SHALL map provider behavior into the shared bounded execution and lifecycle contracts.

#### Scenario: Jort launches with configured model tools
- **WHEN** settings and the tool catalog load without a model invocation or connection action
- **THEN** no provider HTTP transport is initialized and no credential value is requested
- **AND** configured model tools remain discoverable according to their existing connection-state behavior

#### Scenario: Model tool executes
- **WHEN** the shared coordinator dispatches a validated model execution request
- **THEN** Runtime lazily obtains the required credential and provider through injected interfaces and sends only the request's exact bounded content and declared instructions
- **AND** Settings and AppKit receive only typed connection state, result, and failure values rather than transport objects or credential bytes

#### Scenario: Provider reports a failure
- **WHEN** authentication, connectivity, timeout, cancellation, malformed response, or response-limit failure occurs
- **THEN** Runtime maps it to the existing actionable bounded failure before returning it to the lifecycle
- **AND** the provider implementation does not directly mutate invocation UI or canonical document state
