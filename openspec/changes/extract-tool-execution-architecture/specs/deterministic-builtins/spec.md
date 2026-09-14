## ADDED Requirements

### Requirement: Tool packages use an injected execution boundary
Jort SHALL discover, persist, and resolve declarative tool packages without importing a concrete JavaScript runtime and SHALL validate and execute resolved immutable packages through bounded tool-contract interfaces.

#### Scenario: Registry loads packages
- **WHEN** Settings or the package registry discovers bundled and installed candidates
- **THEN** it performs path, size, manifest, precedence, index, and structural validation without initializing QuickJS
- **AND** exposes only valid enabled immutable package values to execution consumers

#### Scenario: JavaScript package is submitted
- **WHEN** a resolved JavaScript package passes executor-specific validation and is explicitly submitted
- **THEN** the shared dispatcher invokes the injected JavaScript executor with its immutable captured package and bounded input
- **AND** Settings and AppKit do not call the QuickJS host directly

#### Scenario: Runtime implementation is replaced
- **WHEN** the JavaScript executor changes from an in-process implementation to another conforming implementation
- **THEN** package discovery, authoring persistence, invocation reduction, and canonical publication continue through the same bounded contracts
- **AND** the package format and user-visible command behavior do not change solely because of the runtime replacement
