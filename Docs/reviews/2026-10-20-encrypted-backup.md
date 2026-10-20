# Review — Encrypted backup (2026-10-20)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5).
- **Why required:** the change touches backup and recovery (AGENTS.md).
- **Scope:** the uncommitted encrypted-backup milestone against `96aef12` (export options).
  Acceptance criteria: `Docs/encrypted-backup-2026-10-20.md`.
- **Runs:**
  - a first run ended on a network error (`getaddrinfo ENOTFOUND opencode.ai`) before reporting.
    Its notes led the author to map local failures while unpacking to `io`, refuse a path under a
    file and a non-blob `DAT`, and treat a 0-byte write and a failed `close` as errors;
  - a second attempt stalled with no output for 45 minutes and was stopped;
  - the milestone review (below);
  - a re-review of the fix pass (below).

## Milestone review

- **Reviewer saw the real diff:** yes. It read `git diff HEAD` and the three new files in full,
  with `Backup.swift`, `PrivateFile.swift`, `MaintenanceView.swift`, the boundary script, plan §13
  and the gap analysis.
- **Reviewer ran tests:**
  - ArenaProtocol `--filter "EncryptedBackup|Maintenance|Backup"`: 24 passed;
  - all of ArenaSuiteCore: 119 passed.
  - Its permissions blocked `Scripts/test-offline.sh`, the boundary check and the app build. The
    author ran them (below).
- **Verdict:** "Not ready for this milestone". There were no Critical or High findings, and it
  called the encryption, staging, exclusive-rename, path-safety and restore-equality core
  "materially sound". It asked for M1, M2, M5 and M6 to be fixed, and M4 and M3 to be fixed or
  documented.

| # | Finding | Outcome |
|---|---|---|
| M1 | The recovery recipe left plaintext readable by others, did not stop after a failed decryption, and left the intermediate archive. | **Fixed.** The recipe sets `umask 077`, works in its own folder, chains decryption and extraction with `&&`, removes `backup.aar` either way, and says the result is plaintext. `macOSToolsOpenAnEncryptedBackup` runs the recipe's lines with zsh and checks owner-only modes on everything recovered, the removal, and that a wrong passphrase leaves the folder empty. |
| M2 | The handoff said plaintext existed only in the plain-copy folder, but every backup check also replays into `arena-suite-replay-*`, which nothing swept after a crash. | **Fixed.** `replayDigest` sweeps replay folders older than an hour. The doc and handoff name both folders and say when a crash's leftovers are swept. New test `plainFoldersACrashLeftAreSwept`, which fails with the sweep reverted. |
| M3 | A read error on the backup file (a failing disk) was reported as damage "with the right passphrase", which could lead a user to delete a good backup. | **Fixed.** The decoder reports a failed read and damaged content alike, so after a decoding failure `open` reads the file again to its end (`readsToTheEnd`). If that fails it is `io`, otherwise damage. New test `aFileThatCannotBeReadIsNotCalledDamaged` covers the classifier; an I/O error in the middle of decoding was not injected. |
| M4 | The app normalizes the passphrase to NFC but the recipe passed raw bytes, so a backup made with a decomposed passphrase could not be recovered with `aea`. It also said the sheet compared its two entries without normalizing. | **Fixed for the recipe:** it normalizes with the system Perl (`Unicode::Normalize`). The test makes a backup with a decomposed, accented passphrase and recovers it with the recipe, after showing that `aea` given the raw text refuses it. **Not a defect in the sheet:** Swift's `==` on strings compares canonical equivalence; `theLimitsAreAppleArchives` pins it. |
| M5 | Plain restore removed an existing `accounts` folder if its file names looked disposable. An account added after `canRestore` was checked keeps the name `registry.json`, so it could be deleted. This predates the milestone; the encrypted restore inherits it. | **Fixed in the plain restore.** `BackupService.install(_:at:)` sets the existing folder aside in one rename, then checks it (names, and an account list that loads empty). Otherwise it puts the folder back and refuses (`targetNotEmpty`). New test `aRestoreNeverRemovesAnAccountAddedMeanwhile`, which fails with the old name-only check. |
| M6 | No test for "never over an existing file". | **Added:** `aSecondBackupInTheSameSecondGetsItsOwnName` (same time stamp: `… 2.aea`, the first file byte-identical). |
| L1 | A file entry without `DAT` was accepted as empty. | **Fixed.** A probe showed Apple Archive writes a size-0 `DAT` for empty files, so a missing one is damage. Tested. |
| L2 | A pipe or device could be opened and block. | **Fixed.** Only regular files are opened (a link to one is followed); a FIFO is refused at once. Tested. |
| L3 | The folder sync after the rename ignores failures. | **Kept, documented** (Known limits): the file is complete and in place; some volumes cannot sync a folder; the plain backup does not sync it at all. |
| L4 | An out-of-rules passphrase when opening is `wrongPassphraseOrDamaged`, and the Open sheet accepts any entry. | **Kept, then narrowed in the re-review (F8):** opening applies only AEA's own byte limits, which no AEA file can be outside. |
| L5 | Encryption and decryption streams were not closed when an error was thrown. | **Fixed.** Both close on every path. |
| L6 | If re-opening a just-written file failed, the app said "Nothing was changed" though the file stays. | **Fixed.** The app says the file was written but did not check out, names it, offers Reveal in Finder, and says not to rely on it. Build-checked. |
| L7 | `import System` had no declared package dependency. | **Rejected.** `System.swiftmodule` and `AppleArchive.swiftmodule` ship in the macOS SDK (`usr/lib/swift`); they are not packages. |
| L8 | The sweep goes by name and age only. | **Kept, documented:** only a second app instance running a backup for over an hour could be affected, and it would fail, never write a wrong file. |

Unverified assumptions raised, and what was done:

- **"Decryption that starts proves the passphrase right":** the doc now calls it observed (a wrong
  passphrase is refused before any plaintext, tested), not specified by Apple.
- **AEA's 20–256-byte limits:** pinned directly by `theLimitsAreAppleArchives` (19 and 257 bytes
  refused, 20 and 256 accepted).
- **`aea` does not prompt and cannot read a pipe:** the doc says this was observed on macOS 27.
- **Percent-encoded names:** `%2E%2E` and `%2F` are tested to stay literal names.
- **Another compression with the same profile:** AEA records the compression in its header and
  decodes it.

Test gaps raised and added: no-overwrite, unsupported profile (a symmetric-key AEA is
`unsupportedFormat`), an empty archive and one without a manifest (`notABackup`), a FIFO, stale
sweeps, a missing `DAT`, the NFD recovery path, and the restore race. Not added:

- a fault-injected read error in the middle of decoding;
- a file-descriptor count after repeated refusals;
- cancellation in the middle of `checkEncrypted` or `restoreEncrypted`;
- the Maintenance UI end to end (the app has no test target).

## Re-review of the fix pass

- **Reviewer saw the real diff:** yes. It read `git diff HEAD`, the new files in full,
  `PrivateFile.swift`, `AccountRegistryStore`, `JournalStore.accountsOnDisk`, the boundary script,
  plan Phase 7 and this file.
- **Reviewer ran tests:**
  - ArenaProtocol `--filter "EncryptedBackup|Maintenance|Backup"`: 30 passed (14 functions);
  - ArenaSuiteCore: 119 passed.
  - Its permissions blocked the boundary check, the app build and `xcrun`. It confirmed L7's
    rejection from the SDK listing.
- **Earlier findings:** it confirmed the fixes.
- **Verdict:** "Not ready for this milestone — narrowly, for two small fixes" (F1, F2), with F3 a
  cheap test, and F4–F10 to fix, document or defer. It judged L3, L4 (once scoped) and L8
  acceptable limits. A first attempt at this re-review stalled with no output and was restarted.

| # | Finding | Outcome |
|---|---|---|
| F1 (High) | A crash between `install`'s renames left the account list in `.previous-accounts-*`. The archive then looked empty, `canRestore` said yes, and nothing ever put the list back. | **Fixed.** `recoverSetAsideAccounts(in:)` puts a set-aside list back when `accounts` is absent, and removes it only when it is an empty list; anything else is kept. It runs at launch (`AppComposition.makeServices`, before anything reads the list) and before every restore. `canRestore` is false while any list is set aside. New test `anAccountListACrashSetAsideIsPutBack`, which fails with the recovery and the guard reverted. |
| F2 (Medium) | The doc's recipe was not the tested one. A re-run after a failed attempt skipped `cd` and wrote plaintext into the current folder, could remove an unrelated `backup.aar`, and reported success. | **Fixed.** The block runs in a subshell: `mkdir … && cd … \|\| exit 1`, with the decryption's status as its exit status. `umask`, `cd` and `exit` do not outlast it. The test reads the block from the doc and substitutes only the passphrase source and the path. It runs the block twice in one place: the second run stops, and a `backup.aar` beside the folder is untouched. |
| F3 (Medium) | That Apple Archive writes `DAT` for empty files rested on a probe. | **Added:** `anEmptyFileWrittenByAppleArchiveOpens` seals a real folder with an empty file through `seal` and opens it. |
| F4 (Low) | The profile is read before authentication, so damage there reads as another format or not a backup. | **Documented** (Known limits). |
| F5 (Low) | The passphrase was checked before the file type. | **Fixed:** the file is looked at first. Tested: a text file with a three-character passphrase is `notABackup`. |
| F6 (Low) | A read error that does not recur still looks like damage; the re-read has no time limit. | **Documented** (Known limits). |
| F7 (Low) | A failed `close` of the decryption stream was reported as damage. | **Fixed:** it is `io`. Not tested (no seam). |
| F8 (Low) | Opening required 20 characters, not AEA's 20 bytes. | **Fixed:** opening normalizes to NFC and leaves the limits to `setPassword`. |
| F9 (Low) | A name over 255 bytes was reported as `io`. | **Fixed:** `safeComponents` refuses it, and `ENAMETOOLONG` maps to `unsafeEntry`. Tested. |
| F10 (Low) | `RENAME_EXCL` may be unsupported on non-APFS volumes. | **Documented** (Known limits). The plain backup has the same requirement. |

Gaps that remain:

- no fault-injected read error in the middle of decoding, and no close seam;
- no kill test at each `install` step: the crash state is built by hand instead;
- no cancellation in the middle of `checkEncrypted` or `restoreEncrypted`;
- no non-APFS volume;
- the Maintenance UI is build-checked and exercised by hand only.

## Check of the second fix pass

- **Reviewer saw the real diff:** yes.
- **Reviewer ran tests:** ArenaProtocol `--filter "EncryptedBackup|Maintenance|Backup"`, 33 passed.
  Its permissions blocked the offline script, the app build and the boundary check.
- **F1 and F2:** fixed "at the level they were reported". It found no code path that removes or
  overwrites a non-empty account list or a journal: "The remaining F1 issue is visibility, not
  bytes."
- **Verdict:** "not ready for this milestone — narrowly", for its findings 1 and 2, with 3 "worth
  taking at the same time" and the rest deferrable. A first attempt at this check stalled with no
  output and was restarted.

| # | Finding | Outcome |
|---|---|---|
| 1 (Medium) | With several set-aside lists and no `accounts`, recovery put back whichever sorted first, even an empty one. A list holding accounts kept beside `accounts` blocked restore with no visible reason. | **Fixed.** Lists that hold something are put back before empty ones. `keptAccountLists()` names whatever is kept; Maintenance shows it in orange and says restore is unavailable while it is there. New test `severalSetAsideListsAndOneThatIsNotAFolder` (both name orders), which fails with name order. |
| 2 (Medium) | `read -rs P` drops spaces at the ends of a passphrase, which the app allows. The test replaced `read`, so it never saw this. | **Fixed.** The block uses `IFS= read -rs P`. The test now substitutes only the path and types the passphrase on standard input, so the block's own `read` runs. A passphrase with spaces at both ends opens its backup; this fails without `IFS=`. |
| 3 (Low) | A file or link named like a set-aside list could be renamed into `accounts`. | **Fixed:** only real folders (`lstat`) are put back. Tested. |
| 4 (Low) | A failed `close` was always `io`, though it may mean damaged trailing content. | **Fixed:** a failed close takes the same path as a decoding failure: the file is read again, and an unreadable file is `io`, otherwise damage. |
| 5 (Low) | A refused restore that had put back a set-aside list left the window showing the old state. | **Fixed:** the app reloads accounts and the archive when a restore fails. Build-checked. |
| 6 (Low) | The MCP server does not report a set-aside list. | **Deferred, documented** (Known limits): it reads without changing anything, so it does not run recovery. |

The fixes for this check were verified by the tests above and by the author's checks below; they
were not reviewed again.

## Checks run by the author

- `swift test --package-path Packages/ArenaProtocol --filter EncryptedBackup`: 18 passed after the
  last fix pass.
- Each of these tests fails with its fix reverted:
  - the `io` mapping;
  - the replay sweep;
  - restore's set-aside check;
  - the crash recovery with its `canRestore` guard;
  - the order of set-aside lists;
  - `IFS=` in the recovery block.
- `bash Scripts/test-offline.sh`: exit 0. `python3 Scripts/check-boundaries.py`: passed.
  `bash Scripts/build.sh Debug`: no Swift warnings.
- The Debug build against a synthetic archive (milestone doc, Results): Encrypt, then Check with
  a wrong and with the right passphrase.
