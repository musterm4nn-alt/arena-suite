# Phase 7 — hardening and personal release (2026-09-24)

Definition of done (plan v3 §13): clean install and upgrade on the target Mac; a backup restores
to an equal archive; release notes list the known limits.

## What was built

| Piece | Where |
|---|---|
| Journal copy (lock-free, record-aligned; sealed segments must match their seal manifests) | `CaptureJournal/JournalCopy.swift` |
| Verify job: journal verifier per account plus a replay into a scratch index, bounded by the live checkpoints read in the same transaction as the live digest | `ApplicationActions/Verification.swift`, `ArchiveService.checkAgainstJournal`, `ArchiveIndex.digestAndCheckpoints` |
| Backup / check / restore (`arena-suite-backup/1` manifest with per-file SHA-256s and the replay digest; staging + `RENAME_EXCL`; restore only into an empty archive) | `ApplicationActions/Backup.swift` |
| Content-free diagnostics (`arena-suite-diagnostics/1`: ordinals instead of IDs, histograms from fixed-vocabulary envelope fields, token-filtered) | `ApplicationActions/Diagnostics.swift` |
| Maintenance sheet (disabled during sync or projection) | `App/MaintenanceView.swift` |
| Packaging (Release build, refuses ad-hoc signing, verifies, installs to `~/Applications`, refuses while running) | `Scripts/package.sh` |
| Release notes and known limits | `Docs/release-notes-1.0.md` |

"Equal archive" means identical journal bytes (per-segment SHA-256) and an index, replayed from the
restored journals, whose content digest equals the one recorded at backup time.

## Evidence

- **Tests.** `MaintenanceTests` (9 tests) cover:
  - backup → check → restore equality, including sealed segments, an append after restore, and
    the registry;
  - a torn active tail being excluded from the backup;
  - changed, missing and extra files rejected (`.DS_Store` tolerated);
  - restore refused into a non-empty archive;
  - a cancelled backup leaving nothing behind;
  - the verify job: clean archive, records appended after the last projection, a flipped byte in
    a sealed segment, and an index that differs from its journal;
  - diagnostics containing no text, titles, IDs, names, claims, paths, user name or account UUIDs,
    and being written 0600 without overwriting.
- **Real archive** (`ARENA_SUITE_REAL_ARCHIVE=… --filter realArchiveVerifies`):
  - The verify job was clean; journals had 30, 31 and 49 records.
  - The live index is identical to a fresh replay.
  - Backup of 3 journals / 110 records → check → restore into a temporary root. The restored replay
    digest equals the source replay, and the segment bytes are equal.
  - UI verify (window-only screenshot, not committed) showed the same result.
- **Scale, 10×** (`ARENA_SUITE_SCALE_TEST=1 --filter scale`): 570 conversations, 1,083 records,
  76.9 MB of bodies.

  | Operation | Result | Budget |
  |---|---|---|
  | Replay | 6.55 s | 60 s |
  | Slowest search | 0.43 s | 1 s |
  | Verify | 7.43 s | 90 s |
  | Backup (including its replay) | 7.15 s | 90 s |
  | Peak RSS | 473 MB | 1.5 GB |

  Sync at 10× was not measured: it is network-bound and paced at ≥ 1 s per request by policy.
- **Clean install.**
  - The installed Release 1.0.0 was run with `CFFIXED_USER_HOME` pointing at an empty folder.
  - It created `Archive/{index,diagnostics}` owner-only, with 0 accounts. The real archive was not
    touched.
- **Upgrade.**
  - `Scripts/package.sh` installed 1.0.0 into `~/Applications`.
  - Launched on the real archive (which Debug builds had created), it showed 57 conversations, and
    all 3 accounts were `signedIn` without a Keychain prompt (same signing identity).
