# Review — Attachment downloads (2026-10-20)

- **Reviewer:** opencode, `deepseek-v4.1-flash-free#high`, `reviewer` agent, run standalone. The
  author was a different model (Claude Opus 5.5).
- **Why required:** the change adds a journal record kind (`attachment.download`), a record
  convention for bodies kept outside the journal (`object_sha256`, `object_size`,
  `object_reference`), a new backup format (`arena-suite-backup/2`) and new verify and restore
  checks (AGENTS.md: journal format, backup and recovery).
- **Scope:** everything uncommitted against `a5271b3`. Acceptance criteria:
  `Docs/attachments-2026-10-20.md`.

## Milestone review

- **Reviewer saw the real diff:** yes (27 files changed plus the five new files).
- **Reviewer ran tests:** ArenaSuiteCore (135 passed) and ArenaProtocol (204 passed). Its
  permissions blocked `Scripts/check-boundaries.py`; it did not run the MCP tests or build the app.
  The author ran all three (below).
- **Verdict:** "not ready for this milestone". It found the core design sound: objects written and
  synced before the record that names them, backups re-hashing and refusing damage, `/1` manifests
  with objects refused, a cookie-less and credential-free transport, link numbering shared by the
  parser and the decoder, and the app reading files only through ApplicationActions. It asked for
  findings 1–3 to be fixed.

| # | Finding | Outcome |
|---|---|---|
| 1 (High) | When the object store refused a 200 body (disk full, a file in place of the folder), the job stopped before recording anything, so the response was lost; the test pinned that. | **Fixed.** The body becomes the record's payload with outcome `not_stored` (new `AttachmentOutcome.notStored`), then the job stops as `storageFailed`. The transcript says the file arrived but couldn't be written, and that its bytes are in the journal. Test renamed to `aFileThatCannotBeStoredIsKeptInTheJournalAndStopsTheJob`: one record, the body as payload, no object name, decoded as `notStored`. |
| 2 (Medium) | Verify skipped the files whenever the journal had any issue, though the transcript says Verify lists every missing file. | **Fixed.** Files are checked from the records that can be read (a torn tail is tolerated by the reader); if none can be listed, the journal's own issue says why. New test `verifyChecksTheFilesOfAJournalThatEndsInATornRecord` (two issues: the tail and the missing file). |
| 3 (Medium) | A redirect (never followed) could put a newly signed link in the record's `Location` header while the record claims `signed_query_omitted`. | **Fixed.** In download records, the query of `Location` and `Content-Location` is replaced by `[omitted]`. New test `aRedirectsSignedQueryIsNotJournaled` (no `X-Amz-Signature` or `X-Amz-Credential` in the envelope). Not observed live: what R2 sends is unknown, so this is a guard. |
| 4 (Low/Medium) | Object files restored or copied by hand stayed readable by others (0644); only folders were tightened. | **Fixed.** `ObjectStore.open` makes object files 0600 again, as the journal does on open. New test `openMakesObjectFilesPrivateAgain`. |
| 5 (Low) | The "downloads stopped" warning was lost when a later journal write failed. | **Fixed.** The generic failure path notes it too. Not tested: the scripted journal can't fail one append on demand. |
| 6 (Low) | The doc claimed more than the boundary script enforces. | **Fixed in the doc:** it names what the script forbids (`ObjectStore`, `attachmentData`, `.objects(for:)`) and says the index's attachment rows stay readable by MCP. |
| 7 (Low) | The doc said the files' hashes and the journal check "prove the bytes" when the digest isn't compared. | **Fixed in the doc:** internal integrity against the manifest and each other; the manifest is not signed. The app's wording was already accurate. |
| 8 (Low) | Without the reader environment, an attachment would show "Reading…" forever. | **Fixed.** A missing reader is an unreadable file. Not tested: the app target has no test target. |
| 9 (Low) | Inline images trusted the stated content type, and a huge image could be decoded whole. | **Fixed.** ImageIO decides the type from the bytes (PNG, JPEG, GIF, WebP, HEIC/HEIF, TIFF, BMP only), refuses more than 100 megapixels, and makes a preview of at most 1 600 pixels off the main actor. Checked in the app on a synthetic archive; not unit-tested. |
| 10 (Low) | The expiry check ran before the one-second spacing, so a link could expire before its request. | **Fixed.** Checked again after the wait. New test `aLinkThatExpiresDuringTheSpacingIsNotRequested` (a link ending at the moment of the request isn't requested; one ending a second later is). It fails with the second check removed. |
| 11 (Low/Medium) | Backup check accepted a listed object that no record names, and restore copied it. | **Fixed.** Check refuses it (`unnamed …`). New test `aBackupThatListsAFileNoRecordNamesIsRefused` (check and restore). |
| 12 (Low) | A link to a folder inside a backup was said to be skipped as a folder. | **Already refused**: `URL` resource values report the link, not a folder, so the old code refused it as "not a regular file" (the new test passes without the change). The link check now comes first for clarity; `aLinkedFolderInABackupIsRefused` pins it. |
| 13–20 (Low observations) | Transport errors counted but not journaled; `attachmentData` not checking the registry; temporary leftovers kept until the next store opens; torn-tail backups; `url(for:)` only used in tests; the temporary file opened without `O_EXCL`/`O_NOFOLLOW`; save-name format characters and byte length; files not reread after a repair. | **19 and 20 fixed:** the save name drops control, format (bidirectional) and separator characters and is cut to 240 bytes; files are read again whenever the archive reloads. **13** matches Arena requests (no response, nothing to record). **14:** the account comes from the transcript shown. **15:** a leftover is a hidden temporary file in a private folder, removed when the store next opens. **16** predates the milestone. **17:** test-only. **18:** the journal's own writer, in a private folder with a random name; unchanged. |

Test gaps it named, and what was done:

- the fixes above: **added** as listed;
- process termination between the object write and the record: **not added** here. A file
  without its record is harmless by design (nothing names it); the journal's crash gate covers
  the record write;
- that the real cookie-less session sends no `Cookie` or `Authorization`: the transport test checks
  there is no jar and that cookies aren't set or accepted; the scripted tests check the requests
  carry no headers.

## Author checks after the fixes

- Reverting the second expiry check makes its test fail; reverting the link check in
  `regularFiles` doesn't (finding 12).
- Suites: core 136, adapter 209, MCP 17, all passing. `Scripts/check-boundaries.py` passes (62
  files). The Debug app builds, and on a synthetic archive (never the real one) shows a stored PNG
  inline, a stored text file as a row, and the text of each other state.

## Re-review of the fix pass

- **First attempt** (same reviewer and model): it read the diff and ran the tests
  (`AttachmentDownloadTests` 26, the attachment, encrypted-backup and maintenance set 60,
  `ObjectStoreTests` 8, all passed), then the provider's rate limit cut it off before its verdict.
  Its working notes held only Low candidates:
  - Backup check didn't compare a listed object's size with the file (only restore did), so a
    backup could pass check and fail restore. **Fixed:** check compares it. New test
    `aListedSizeThatDiffersIsRefusedByCheckAsByRestore`.
  - The `attachments` table's new columns outside the digest: **not so.** The digest hashes every
    column of every row (`SELECT *`).
  - Verify skipping the files when a journal with issues can't be listed at all: by design, the
    journal's issue says why.
  - The decoder keeping only what the index needs from a download record: the rest stays in the
    journal.
  - No tests for the app's attachment view: the app target has no test target; checked in the app.
- Suites after this: core 136, adapter 210, MCP 17, all passing; the boundary check passes.
- **Second attempt** (a short re-review of each fix, without rerunning tests): rate-limited at
  once, on this model and on `glm-5.3-flash-free`, then six more times over an hour (2026-10-21).
  **The re-review of the fix pass is still to be done.**
