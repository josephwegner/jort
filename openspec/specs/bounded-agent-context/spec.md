# bounded-agent-context Specification

## Purpose

Define author-controlled model-tool contracts that limit each request to explicit instructions and exact captured tool input.

## Requirements

### Requirement: Model-backed tools use author-controlled execution contracts
Jort SHALL support `model` as a tool executor type alongside `javascript` and SHALL require each model-backed definition to declare exactly one input mode, one output operation, bounded instructions, and one model identifier from Jort's bundled catalog.

#### Scenario: Tool author configures a model-backed tool
- **WHEN** a user creates or edits a model-backed tool
- **THEN** Settings requires the user to select its input mode, output operation, instructions, and bundled model before the definition can become executable
- **AND** saves those values as versioned tool configuration

#### Scenario: Model execution begins
- **WHEN** a valid model-backed invocation is submitted
- **THEN** Jort captures the definition's input mode, output operation, instructions, selected model, package identity, and exact normalized `content`
- **AND** later definition changes cannot alter that submitted generation

#### Scenario: Model response attempts to control the invocation
- **WHEN** a model response contains instructions or structured text requesting another input range, output operation, tool invocation, or Merge policy
- **THEN** Jort treats that material only as bounded output text
- **AND** retains the author-selected input and output contract

### Requirement: Tools Settings authors model executors explicitly
Jort SHALL expose an executor selector for custom tools and SHALL present executor-specific editing without treating model instructions as JavaScript source.

#### Scenario: Model executor is selected
- **WHEN** a custom tool draft selects the `model` executor
- **THEN** Settings presents a bounded plain-text instructions editor and filterable model picker
- **AND** hides the JavaScript source editor without executing or synthesizing JavaScript

#### Scenario: JavaScript executor is selected
- **WHEN** a custom tool draft selects the `javascript` executor
- **THEN** Settings presents the existing JavaScript source editor and validation behavior
- **AND** presents no model or instruction fields as part of that executor

#### Scenario: Executor change would discard draft content
- **WHEN** a dirty custom draft changes executor type and the transition would discard executor-specific content
- **THEN** Jort requires deliberate confirmation before applying the change
- **AND** cancellation preserves the complete draft, selection, and local undo state

#### Scenario: Model-backed tool is saved
- **WHEN** a valid model-backed draft is saved
- **THEN** Jort commits its definition through the ordinary versioned tool catalog without executing the model or checking the OpenRouter connection
- **AND** preserves the normal Settings Save behavior

### Requirement: Model selection uses a bundled curated catalog
Jort SHALL bundle a bounded curated model catalog and SHALL persist model selections by stable OpenRouter model identifier without fetching the catalog during Settings use.

#### Scenario: User opens the model picker
- **WHEN** a model-backed tool's model field is activated
- **THEN** Jort presents a compact filterable list with friendly model names and restrained provider or family metadata
- **AND** performs no network request

#### Scenario: User filters models
- **WHEN** the user enters a model query
- **THEN** Jort filters the bundled catalog by visible name and supported metadata while keeping keyboard selection and accessibility available
- **AND** stores the selected stable OpenRouter identifier rather than its display label

#### Scenario: User is not connected to OpenRouter
- **WHEN** the user creates or edits a model-backed tool while disconnected
- **THEN** the complete bundled model catalog remains available for selection
- **AND** saving valid tool configuration does not begin authentication

#### Scenario: Selected model leaves the bundled catalog
- **WHEN** an application update no longer contains a definition's selected model identifier
- **THEN** Jort preserves the stored identifier and marks the tool unavailable with an actionable diagnostic
- **AND** does not silently select or execute another model

### Requirement: Model requests receive only exact tool input
Jort SHALL construct each model request from the tool's bounded instructions and the exact `content` captured by the existing input-mode contract and SHALL expose no additional context or host authority.

#### Scenario: Contained or contextual input is submitted
- **WHEN** a model-backed tool using canonical input begins execution
- **THEN** Jort sends the exact normalized content extracted and locked by the shared invocation system
- **AND** sends no characters outside that invocation's author-selected input scope

#### Scenario: Ephemeral input is submitted
- **WHEN** a model-backed tool using ephemeral input begins execution
- **THEN** Jort sends the exact normalized ephemeral `content` captured at Run
- **AND** does not insert or persist that prompt as document text

#### Scenario: Model-backed tool requests broader context
- **WHEN** a model-backed definition, its instructions, or its response attempts to read the document, history, filesystem, settings, capture, connectors, processes, shell, JavaScript runtime, or application state
- **THEN** Jort provides none of that context or authority
- **AND** the request remains limited to instructions and captured `content`

### Requirement: Model configuration stays out of invocation chrome
Jort SHALL resolve each model-backed tool's saved model configuration before execution and SHALL use the ordinary tool invocation presentation without adding provider or model selection controls to the editor.

#### Scenario: Model-backed command is accepted
- **WHEN** the user accepts completion for a configured model-backed slash command
- **THEN** Jort presents the same input and Run affordances required by its declared input mode
- **AND** shows no provider name, model picker, or per-run model choice in the invocation

#### Scenario: User changes a tool's model
- **WHEN** the user selects another supported model in Tools Settings and saves the definition
- **THEN** later invocations use the newly saved model
- **AND** an already submitted generation continues with its captured model configuration

### Requirement: Bundled model-backed tools are ordinary templates
Jort SHALL ship `/ask` and `/rewrite` through the same bundled template, registry, enablement, inspection, duplication, invocation, and lifecycle paths used by other tools.

#### Scenario: Ask template is inspected
- **WHEN** Jort loads the bundled `/ask` definition
- **THEN** it declares the `model` executor, `ephemeralMultiline` input, and `insert-at-invocation` output
- **AND** includes bounded visible instructions and a supported bundled model selection

#### Scenario: Rewrite template is inspected
- **WHEN** Jort loads the bundled `/rewrite` definition
- **THEN** it declares the `model` executor, `contextual` input, and `replace-context` output
- **AND** includes bounded visible instructions and a supported bundled model selection

#### Scenario: User customizes a bundled model tool
- **WHEN** the user duplicates `/ask` or `/rewrite` in Settings
- **THEN** Jort creates a user-owned draft whose executor, instructions, model, input mode, and output operation can be changed
- **AND** preserves the bundled template as a restorable independent definition

### Requirement: Disconnected model tools remain discoverable
Jort SHALL keep valid enabled model-backed tools in slash-command completion when OpenRouter is disconnected and SHALL block only their execution until connection is available.

#### Scenario: Disconnected user opens completion
- **WHEN** OpenRouter is disconnected and the user types a matching slash query
- **THEN** configured model-backed tools appear with ordinary tool completion behavior
- **AND** no authentication or provider initialization occurs

#### Scenario: Disconnected user attempts Run
- **WHEN** the user submits a model-backed invocation without an available OpenRouter credential
- **THEN** Jort keeps the invocation editable and presents an actionable validation warning directing the user to Models Settings
- **AND** does not lock source, initialize a model request, or mutate canonical output
