## 1. Dependency and release feasibility

- [ ] 1.1 Start implementation with `./scripts/validate changed --plan-only`; inspect supported validation lanes and current model/runtime architecture before edits.
- [ ] 1.2 Prove and pin compatible MLX Swift language-model dependencies, preserving the macOS 14 baseline and supported cloud-build architectures; document toolchain/capability gates and confirm release Metal resources and signing through the validation wrapper.
- [ ] 1.3 Pin the Qwen3-1.7B-4bit immutable revision, required files/sizes/SHA-256 hashes, approved delivery/redirect hosts, bounded download size, and license/attribution metadata in a release-controlled installation manifest.

## 2. Provider-aware model contracts

- [ ] 2.1 Add explicit backend metadata and a stable local Qwen identity to the curated catalog while preserving all existing OpenRouter IDs and bundled ask/rewrite defaults.
- [ ] 2.2 Define injected per-model readiness, installation status/progress, typed local failure, and model-asset management interfaces without exposing MLX objects to Contracts, Settings, or AppKit.
- [ ] 2.3 Replace global OpenRouter preflight with selected-model readiness and add backend routing beneath the shared dispatcher; preserve captured generations and cloud-only credential/authentication callbacks.
- [ ] 2.4 Add deterministic contract/routing tests for ID compatibility, unavailable IDs, local-without-cloud readiness, no fallback, no eager initialization, and unchanged saved tool behavior.

## 3. Verified optional model assets

- [ ] 3.1 Implement a separate Jort-owned model/staging root with bounded no-follow path validation, installation manifests, and atomic verified publication outside document/history storage and shared Hugging Face caches.
- [ ] 3.2 Implement explicit HTTPS download with restricted redirects, expected file/hash/size checks, total/disk bounds, progress, cancellation, bounded errors, and retry without cloud credentials or document content.
- [ ] 3.3 Implement readiness/integrity checks, safe abandoned-staging cleanup, coordinated execution leases, and explicit removal that rejects active use and reports incomplete deletion honestly.
- [ ] 3.4 Test successful installation and injected interruption, hash mismatch, excess bytes, bad redirect, traversal/symlink, disk failure, relaunch cleanup, failed replacement, and removal/load races using fixture assets and fake transports.

## 4. Cold native MLX execution

- [ ] 4.1 Implement an actor-isolated local execution service with one admitted session at a time, cancellation-aware waiting, a 90-second queue/load/execution deadline, and no hot model cache or prewarming.
- [ ] 4.2 Load only verified local assets without network authority; apply the Qwen chat template with thinking disabled and only exact captured instructions/input.
- [ ] 4.3 Enforce initial 4,096 prompt-token and 1,024 output-token budgets plus total context, byte, line, and normal-stop requirements; return complete text or typed failure without input truncation or partial publication.
- [ ] 4.4 Implement terminal cleanup on success, error, cancellation, and timeout: drain GPU work, release model/tokenizer/KV/iteration references, clear safe request-owned MLX caches, and only then permit the next load.
- [ ] 4.5 Add fake-backed loader/generator/resource tests covering cancellation during queue/load/decode, deadline expiry, limit failures, cleanup on every terminal path, serial admission, independent cloud execution, and ignored late results.

## 5. Settings and application integration

- [ ] 5.1 Compose the local asset manager, capability checks, readiness service, and provider router lazily at the app boundary while keeping OpenRouter OAuth/Keychain composition unchanged.
- [ ] 5.2 Extend Models Settings with separate Local/OpenRouter sections and accessible size/privacy/cold-load descriptions, supported/unsupported/ready states, Download/Cancel/Retry/Remove controls, and bounded errors.
- [ ] 5.3 Extend the existing Tools Settings picker with local/cloud labeling and Qwen selection without requiring assets at Save; preserve Duplicate to Customize and command-conflict rules with no invocation-level picker.
- [ ] 5.4 Add AppKit/settings tests for keyboard/VoiceOver semantics, no side effects on pane opening or model selection, explicit download actions, persisted model selection, removal state, and independent local/cloud statuses.
- [ ] 5.5 Verify local model authority and dependency imports stay outside JavaScript workers, document/storage modules, and AppKit implementations; extend architecture checks as needed.

## 6. Integration verification and documentation

- [ ] 6.1 Run focused checks through `./scripts/validate` for model/runtime, asset manager, Settings, and shared invocation lifecycle; cover pending-output publication, Merge, Dismiss, Undo, cancellation, and interrupted relaunch with local fake providers.
- [ ] 6.2 Document local installation/removal, approximately 984 MB download, Apple-silicon requirements, small-model limitations, cold-load policy, no cloud fallback, and customizing ask/rewrite including command conflict resolution.
- [ ] 6.3 Add an opt-in real-device check through the validation workflow that records cold load, prompt processing, generation, total latency, and peak/post-cleanup MLX allocation metrics without logging prompt/response content; validate repeated success/cancel/error cleanup and editor responsiveness.
- [ ] 6.4 Verify a downloaded model works with network and OpenRouter unavailable, thinking disabled, no inference HTTP/credential access, no retained model/KV cache between requests, and no inference content persisted outside normal output publication.
- [ ] 6.5 Verify signed release packaging and DMG exclude weights and Python/server dependencies, retain required MLX/Metal resources and attribution, and preserve supported non-local build behavior.
- [ ] 6.6 Complete independent scoped review, address findings, and run `./scripts/validate gate` once after the final implementation change; inspect bounded result summaries and record remaining manual hardware checks honestly.
