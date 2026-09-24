# Phase 6 — exports

Plan v3 §12 and §13 (Phase 6). 2026-09-24. Code: `ApplicationActions/ExportService.swift`.

## Definition of done (N-014)

| Criterion | Result |
|---|---|
| Deterministic output for frozen inputs | An export reads one conversation snapshot (a journal record plus its index projection) and contains no export time. **Real archive:** all 51 conversations with snapshots × 3 formats, exported twice = 306 files, every pair byte-identical. |
| Staging + atomic move; no silent overwrite | Written to a temp file in the destination, fully synced, then hard-linked to the first free name (`name.md`, `name 2.md`, …; `link` never replaces a file), temp removed. |
| Cancellation / failure leaves nothing partial | A cancelled or failed export leaves no file under a final name (tested). |
| Telemetry excluded by default | Normalized JSON and Markdown come from the index, which never holds `metadata`. Raw JSON masks every `metadata` subtree by default and declares it (`byte_fidelity: transformed`, policy `mask-metadata/1`, original and exported SHA-256). Exact bodies only via an explicit, confirmed menu item, marked in `sensitivity`. **Real archive:** no telemetry marker in any default export (raw payloads included). |

## Formats

- **Raw JSON** (`arena-suite.raw-export/1`): scope (account, conversation, snapshot sequence, record digest,
  decoder, observation layer), the record's location, envelope, base64 body, hashes, fidelity, transformations.
- **Normalized JSON** (`arena-suite.normalized/1`): conversation facts, ordered messages with blocks
  (`source_pointer` into the raw body), attachments (no URLs), model claims (`verified_identity: false`,
  with source), feedback, and an explicit `excluded` list.
- **Markdown**: turns and lanes via `TranscriptLayout`, reasoning quoted, tool calls/results and sources in
  fences that embedded backticks cannot close, votes, and a footer naming the source record, its SHA-256,
  the decoder, and what the Markdown view leaves out.

UI: format picker (remembered) and Export button in the transcript toolbar; Export to Downloads,
Export to Folder…, and (Raw JSON only) the confirmed exact-bodies export; result line with Reveal in Finder.

Scope limits: one conversation snapshot per export; all-conversation and dataset exports are later work
(plan §14).
