## ADDED Requirements

### Requirement: Local model installation is explicit and independent
Jort SHALL offer `mlx-community/Qwen3-1.7B-4bit` as an optional local model on supported Apple-silicon Macs alongside OpenRouter, SHALL exclude weights from the app and DMG, and SHALL expose accessible installation status and Download, Cancel, Retry, and Remove actions in Models Settings independently of cloud connection state.

#### Scenario: User opens settings without an installed model
- **WHEN** the user opens Models Settings or selects Qwen in Tools Settings
- **THEN** Jort displays local capability, approximate download size, local execution/privacy information, and installation state
- **AND** performs no download, model load, inference, credential lookup, or connection check

#### Scenario: User explicitly downloads Qwen
- **WHEN** a supported user activates Download
- **THEN** Jort starts a bounded installation with accessible progress and cancellation
- **AND** indicates readiness only after successful verification and atomic installation

#### Scenario: Device does not support local inference
- **WHEN** Jort cannot support the configured local runtime on the device
- **THEN** it exposes an actionable unsupported status and prevents local download/execution
- **AND** preserves supported OpenRouter and non-model functionality

### Requirement: Model assets are pinned and safely managed
Jort SHALL download only release-pinned model/tokenizer/configuration assets from approved HTTPS delivery destinations, enforce exact file paths, expected sizes, hashes, and total transfer bounds, and atomically install verified assets under a separate Jort-owned model directory without following links or writing outside that root.

#### Scenario: Download is interrupted or fails verification
- **WHEN** installation is cancelled, interrupted, exceeds a bound, or encounters an invalid path, redirect, size, or hash
- **THEN** incomplete assets remain unavailable for inference and a bounded retryable status is exposed
- **AND** a valid prior installation remains intact and abandoned owned staging can be safely cleaned

#### Scenario: User removes an idle installation
- **WHEN** the user explicitly removes an installed model that has no active execution lease
- **THEN** Jort deletes only the known owned model assets and associated staging/metadata without following links
- **AND** marks the model unavailable without changing tool definitions, external caches, or document/history data

#### Scenario: User removes a model in use
- **WHEN** removal is requested while local execution owns the installation
- **THEN** Jort reports that removal requires completion or cancellation and offers retry afterward
- **AND** does not delete files beneath an active load or generation

### Requirement: Every local query cold loads and releases its model
Jort SHALL load model weights and tokenizer only for an admitted explicit local execution and SHALL discard model, tokenizer, KV/prompt state, and reusable request-owned MLX allocations after success, failure, timeout, or cancellation, without prewarming or retaining a hot model between requests.

#### Scenario: Local query completes
- **WHEN** a local query reaches a terminal state
- **THEN** Jort drains outstanding GPU work and completes model-state and allocator-cache cleanup before another local load starts
- **AND** retains no model, tokenizer, prompt cache, or KV state for a later request

#### Scenario: Two local invocations are submitted
- **WHEN** another local request arrives during an active local session
- **THEN** Jort admits at most one model load/generation session at a time and lets queued requests cancel or expire without allocating another model
- **AND** does not prevent independent cloud or JavaScript execution

#### Scenario: Application is otherwise idle
- **WHEN** the user launches Jort, edits, browses tools/settings, or returns after a previous local query
- **THEN** Jort does not load or prewarm a local model
- **AND** cold-loading latency remains an accepted part of the next explicit query

### Requirement: Local inference is bounded and non-thinking
Jort SHALL disable Qwen thinking through the supported chat template, use only captured tool instructions and exact captured input, enforce explicit tokenized prompt/context and generated-token limits in addition to existing byte/line limits, and return only one complete text result or typed failure within a 90-second queue/load/execution deadline.

#### Scenario: Input exceeds the local context budget
- **WHEN** the exact tokenized request exceeds the configured local prompt or total context budget
- **THEN** Jort returns an actionable limit failure and performs terminal cleanup
- **AND** neither truncates input nor retries with a cloud provider

#### Scenario: Generation reaches an output bound
- **WHEN** generation exceeds token, byte, or line bounds or reaches the token cap before a normal stop
- **THEN** Jort returns a typed limit failure with no partial published output
- **AND** completes the same cleanup used for successful requests

#### Scenario: User cancels or the deadline expires
- **WHEN** cancellation or the deadline occurs during queueing, loading, or generation
- **THEN** Jort stops cooperatively at safe boundaries, invalidates late output, and drains and releases any allocated local resources
- **AND** preserves the shared invocation cancellation/error behavior without mutating unrelated editor state

### Requirement: Local inference has no cloud authority or durable prompt cache
Jort SHALL execute installed local models without network access or cloud credentials, SHALL never silently substitute a model/provider, and SHALL not persist local prompts, responses, tokenizer input, or KV state in model assets, installation metadata, or diagnostics.

#### Scenario: Installed Qwen executes offline
- **WHEN** a user runs a configured installed local model without network connectivity or an OpenRouter connection
- **THEN** local inference proceeds without a credential lookup or network request
- **AND** returns through the ordinary bounded model result path

#### Scenario: Local execution cannot proceed
- **WHEN** local assets are absent/corrupt or local loading/generation fails
- **THEN** Jort reports a bounded local diagnostic and never sends the request to OpenRouter or another destination
- **AND** does not change OpenRouter credential or connection state

#### Scenario: Local state is persisted
- **WHEN** Jort records installation/readiness metadata or diagnostics
- **THEN** those records contain only bounded non-content metadata and no inference inputs, outputs, or caches
- **AND** normal document/output persistence continues exclusively through the existing tool lifecycle
