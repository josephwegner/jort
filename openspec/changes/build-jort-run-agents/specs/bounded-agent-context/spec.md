## ADDED Requirements

### Requirement: Registered agents are invoked in place
Jort SHALL recognize exact registered `@agent` tokens at their actual logical-line and character position, SHALL decorate that invocation line, and SHALL leave unmatched or abandoned text ordinary.

#### Scenario: Registered agent is typed
- **WHEN** an exact registered agent token is committed at a valid token boundary
- **THEN** Jort presents pending agent identity, provider identity, context control, and Run on that invocation line
- **AND** no request starts before explicit execution

#### Scenario: Agent token is unmatched
- **WHEN** an `@` token does not match a registered agent
- **THEN** Jort creates no invocation or provider work and leaves the token as ordinary text

### Requirement: Submitted context is exact and visible before Run
Jort SHALL default each agent invocation to prompt-only context and SHALL visibly decorate the exact ranges included by any selected full-line or agent-declared bounded context mode before execution.

#### Scenario: Prompt-only context is selected
- **WHEN** the user has not granted broader context
- **THEN** the manifest includes only the explicit invocation prompt range
- **AND** excludes other text on the same line and elsewhere

#### Scenario: Full-line context is selected for a mid-line invocation
- **WHEN** the user selects full-line context for an invocation entered between other text
- **THEN** the exact complete LF-delimited logical line is shaded and submitted
- **AND** includes text before and after the invocation

#### Scenario: Bounded nearby context is selected
- **WHEN** a configured agent declares and the user selects a bounded before/after mode
- **THEN** Jort shades and labels the exact ordered ranges that will be submitted
- **AND** submits no text outside them

#### Scenario: User changes context
- **WHEN** the user changes the context option before Run
- **THEN** visible decoration, labels, and the pending manifest update from the same ranges

### Requirement: Every run captures an immutable auditable manifest
Jort SHALL capture invocation and submitted ranges, exact submitted UTF-8 text, base generation, stable anchors, hashes, agent and provider identity, capabilities, and run-scoped consent before dispatch.

#### Scenario: Run begins
- **WHEN** the user activates Run or Shift-Return
- **THEN** Jort freezes one manifest before provider execution
- **AND** later edits cannot alter what that run receives

### Requirement: Broad context requires fresh consent
Jort SHALL require a fresh content preview and confirmation for every whole-document or exact-history-revision read and SHALL provide no permanent authorization for either capability.

#### Scenario: Whole-document access is requested
- **WHEN** an agent requests the complete current document
- **THEN** Jort previews the exact content and provider/network destination before asking for confirmation
- **AND** denial leaves the run unsubmitted

#### Scenario: History access is requested
- **WHEN** an agent requests a specific revision
- **THEN** Jort identifies and previews that exact verified revision before confirmation
- **AND** consent applies only to that revision and run

#### Scenario: Same agent requests broad access again
- **WHEN** a later run requests document or history access previously granted
- **THEN** Jort requires a new preview and confirmation

### Requirement: Context controls are accessible
Jort SHALL expose invocation identity, provider/network identity, context options, exact-range summaries, consent previews, and Run through keyboard and accessibility APIs.

#### Scenario: VoiceOver reviews context
- **WHEN** a VoiceOver user focuses a pending agent invocation
- **THEN** Jort announces selected context and provider identity and permits changing or previewing context before Run
