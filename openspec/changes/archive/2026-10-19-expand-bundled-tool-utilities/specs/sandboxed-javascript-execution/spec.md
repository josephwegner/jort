## MODIFIED Requirements

### Requirement: Worker authority is denied by sandbox and message design
The broker SHALL have App Sandbox and Hardened Runtime with no network, arbitrary user-file, file-selection, app-group, Keychain access-group, Apple Events, device, or temporary-exception entitlement, and the worker SHALL have Hardened Runtime and inherit only that static sandbox while receiving no ambient authority-bearing value.

#### Scenario: Worker attempts prohibited authority
- **WHEN** a signed native containment probe under the worker sandbox attempts representative user-file access, network client/server access, Jort credential lookup, Apple Events, protected device access, or subprocess creation
- **THEN** macOS denies each operation or the worker's process limit prevents it
- **AND** the broker/main process remains usable and records no source, input, output, or credential in diagnostics

#### Scenario: Worker request is constructed
- **WHEN** one immutable JavaScript package is prepared for execution
- **THEN** the request contains only its normalized manifest/contract, source, exact input, captured clock/UUID, generation/correlation identity, and declared bounds; contract 2 additionally carries bounded validated arguments, local calendar/locale values, entropy, and pure text-analysis data
- **AND** contains no document snapshot, settings store, credential, provider, filesystem authority, destination path, endpoint capability, bookmark, native object, or callback capability; literal URLs in note text remain ordinary data

#### Scenario: Entitlements are inspected
- **WHEN** the built broker and worker signatures are decoded
- **THEN** the broker has only its approved minimal sandbox/hardening entitlements and the worker's App Sandbox keys are exactly app-sandbox plus inherit
- **AND** their stable code identifiers and expected signer relationship differ from one another and match the checked target manifest

#### Scenario: Script requests a host action
- **WHEN** a contract 2 worker returns one typed action request
- **THEN** the broker transports bounded inert data only, without executing that action
- **AND** app-side validation and injected host services enforce tool-host-actions independently of manifest declarations

### Requirement: JavaScript IPC is exact-version, allowlisted, correlated, and bounded
Jort SHALL use an explicitly versioned protocol 2 for contract 2 data while preserving contract 1 behavior through an adapter, with only fixed primitive fields and bounded arrays, SHALL reject unknown/missing/wrong-typed fields and unsupported versions, SHALL correlate replies by authenticated peer, 128-bit nonce, invocation ID, and lifecycle generation, and SHALL enforce every independent and summed length before application copying or decoding.

#### Scenario: Maximum valid request is sent
- **WHEN** a request contains at most a 16 KiB contract, 256 KiB source, min(package byte limit, 1 MiB) input, at most 1 MiB captured metadata (including at most 16 KiB entropy), and 2.5 MiB total payload
- **THEN** both client and broker accept its lengths before copying/decoding and the child accepts its fixed header before allocating payload buffers
- **AND** each layer still validates the decoded semantic bounds

#### Scenario: Maximum valid response is returned
- **WHEN** a worker returns output within min(package byte limit, 1 MiB), min(package line limit, 100,000 lines), and the 1.125 MiB response envelope
- **THEN** the broker and client accept exactly one complete correlated success frame
- **AND** any public error is at most 512 UTF-8 bytes and any private diagnostic is at most 4 KiB without sensitive payload data

#### Scenario: Length or frame is invalid
- **WHEN** any independent length, summed envelope, fixed tag, hash, UTF-8 value, field allowlist, text/report/action/error exclusivity, frame count, trailing data, or declared size is invalid
- **THEN** the receiving layer rejects it before allocating or decoding the declared payload and terminates/abandons the generation
- **AND** returns only a bounded typed protocol or limit failure

#### Scenario: Reply is stale or mismatched
- **WHEN** a reply has a valid shape but its peer identity, protocol, nonce, invocation, or generation does not match the outstanding request
- **THEN** Jort rejects it without emitting success or document effects
- **AND** invalidates the affected channel when authenticity or protocol integrity is uncertain

#### Scenario: Protocol versions disagree
- **WHEN** client, broker, or worker versions do not agree on the exact frame schema
- **THEN** the request fails before execution with a bounded compatibility error
- **AND** no participant silently downgrades an action result to text or ignores unknown fields
