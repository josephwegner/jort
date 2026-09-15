# Implementation verification

- Full foundation and native run: **244 tests passed** (136 foundation, 108 native).
- Final focused run after recovery and UI refinements: **65 tests passed** (23 package registry, 19 model tools, 10 Settings, 13 native Settings workspace).
- OpenSpec strict validation and `git diff --check` passed.

The registry suite injects failures at staging creation, each file write/sync, directory sync, package verification, generation rename/sync, recovery creation, index write/sync/rename, post-replacement directory sync, in-memory publication, and cleanup. It checks old authority before replacement and visible new authority with preserved recovery holds after replacement. Additional tests cover conservative migration, migration failure, untrusted index preservation, bounded history, deletion failure, damaged current/previous packages, links, unexpected entries, and cleanup retry.

Native fixtures independently suspend validation and persistence. They verify single submission across repeated Save and transition callers, waiting beyond the former two-second timeout, disabled controls, accessible saving status, failure/conflict/uncertainty draft and caret preservation, undo-manager preservation, pane and termination outcomes, Save/Discard/Cancel sheets, and successful close. Finder reveal is wired to the installed recovery directory; the native fixture verifies recovery-action availability without opening Finder during tests.

Recovery files are visible `Recovery-<UUID>` directories. Surviving recovery holds suspend cleanup across restarts and later saves; a limit of 32 holds refuses additional publication before another generation is written. README documents copying files, deliberate catalog repair, resuming cleanup, and the version-two rollback constraint. There is no automatic promotion of recovery sources.
