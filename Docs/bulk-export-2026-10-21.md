# Bulk export of the listed history (2026-10-21)

The single export (`Docs/export-options-2026-10-20.md`) works on one snapshot. This milestone exports
everything the sidebar lists in one step.

## Acceptance criteria

1. The history header has an export button (Export Listed Conversations). It acts on:
   - the filtered history list;
   - or, while search results are shown, the conversations of those results, in result order, within
     the filters. The search reads at most 1 000 hits, and the sheet says so when it reached that limit.
2. The sheet:
   - offers the single export's scopes and formats, sharing its remembered choice;
   - refuses Last answer with Raw JSON;
   - says how many conversations are listed and how many have no transcript;
   - exports to Downloads or to a chosen folder;
   - shows progress with Stop, then the result with Show in Finder.
   - Exact raw bodies are not offered in bulk.
3. Each conversation's latest snapshot is frozen when the export starts. A sync running meanwhile
   doesn't change which snapshot is exported. Each file has exactly the bytes a single export of that
   snapshot writes. A conversation listed twice is exported once.
4. Everything goes into one new folder, `Arena Suite export <yyyy-MM-dd HH.mm.ss>` (` 2`, … if taken):
   - it is built as a hidden `.arena-suite-bulk-<uuid>.partial` folder (0700) and renamed without
     replacing anything only when complete;
   - Stop or a write failure removes it, and the next export removes leftovers of a killed one.
5. `manifest.json` (`arena-suite-bulk-export/1`) gives:
   - the format, scope, redaction policy, `exact_raw_bodies` and the number of conversations requested;
   - per file: account, remote ID, snapshot sequence, file name, bytes and SHA-256;
   - per conversation left out: account, remote ID and reason.
6. A conversation that can't be exported is left out with its reason, and the export goes on. The
   reasons: `not_in_archive`, `no_snapshot` (listed only), `no_last_answer`,
   `last_message_not_in_snapshot`, `last_messages_unreadable`, `raw_record_unavailable`.

## Code

- `ApplicationActions.BulkExportService`: freezes the snapshots, then uses `ExportService.export`
  for each file and `ExportService.write` for the manifest. The folder is renamed with
  `renamex_np(RENAME_EXCL)`.
- `ArchiveModel.bulkTargets`, `bulkExport`, `stopBulkExport`.
- `BulkExportSheet` in `App/SidebarView.swift`. The Debug-only `--preview-bulk-export` flag opens
  the sheet.

## Evidence

- **`BulkExportTests` (3 tests):**
  - the folder holds only the finished files, manifest hashes match, and each file's bytes match a
    single export;
  - skips are recorded, including a duplicate exported once;
  - a second folder in the same second gets its own name;
  - a missing last answer is skipped;
  - the Raw JSON / last-answer refusal writes nothing;
  - a cancelled export and a killed export's leftover leave nothing.
- **Debug app on a synthetic archive:** the sheet renders with the listed-only count.
- **Not checked in the app:** clicking Export itself. It is covered by the service tests.
