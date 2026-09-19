## Why

Jort's durability mechanisms intentionally retain multiple copies, but users currently lack the advertised save/recovery commands and cannot deliberately remove historical copies of sensitive text. Recovery loading also allocates complete files before enforcing size limits, so malformed or hostile recovery files can consume excessive memory precisely when startup is already degraded.

## What Changes

- Add File-menu Save/Retry Save with Command-S and Save Recovery Copy, backed by explicit actions rather than autosave timing; keep both out of Pocket.
- Surface recovery corruption, oversize/link/type rejection, automatic recovery, and load failure through typed, actionable storage state while preserving immediate recovery editing and the source files.
- Inspect and open recovery files without following links, reject non-regular or unexpectedly linked files, and enforce role-specific byte limits during bounded reads before decoding.
- Add a confirmed File-menu Clear History and Recovery Data action that preserves the exact authoritative current document while removing every older Jort-managed logical copy.
- Rebuild and atomically install a current-only SQLite store, checkpoint/truncate WAL state, validate it, then remove old history (including milestones), recovery files, legacy recovery data, diagnostic backups, and abandoned replacement/staging directories.
- Make purge progress and partial cleanup typed and recoverable; never report completion while a known Jort-managed old copy remains.
- Retain at most two verified diagnostic backups of each `PreMigration-*` and `Damaged-*` class and automatically remove backups older than 30 days, but only after a healthy canonical store is verified.
- State the deletion promise accurately: Jort removes logical copies it manages, but does not claim forensic erasure of APFS blocks, snapshots, Time Machine, or user-exported copies.

## Capabilities

### New Capabilities
- `private-data-controls`: Defines the confirmed current-document-preserving purge, diagnostic-backup retention, managed-copy inventory, crash recovery, progress/failure states, and the logical-deletion promise boundary.

### Modified Capabilities
- `resilient-document-storage`: Adds bounded no-follow recovery ingestion, typed recovery attention, explicit Save/Retry and recovery-copy actions, current-only store rebuilding, and safe cleanup ordering.
- `local-version-history`: Allows a deliberate confirmed purge to remove all revisions including milestones while leaving ordinary pruning and restore durability unchanged.
- `native-editor`: Exposes quiet File-menu persistence/recovery actions and actionable recovery/purge state without blocking editing, stealing focus, or entering Pocket.

## Impact

- Extends persistence/store protocols and typed state in `PersistenceController.swift`, `SQLiteStore.swift`, `RecoveryCheckpoints.swift`, history storage/retention, and new bounded file-reading and managed-copy inventory helpers.
- Adds File menu actions and validation in `Jort/JortApp.swift` and editor/storage presentation in AppKit, coordinated with the active lossless-startup and presentation-lifecycle changes.
- Adds failure-injection stages and fixtures for oversized sparse files, symlinks, hard links, special files, file growth during read, WAL residue, every purge publication boundary, and crash resumption.
- Does not add recovery-copy import, encrypted storage, crypto-erasure, main-app sandboxing, or deletion of external backups/user-selected exports.
