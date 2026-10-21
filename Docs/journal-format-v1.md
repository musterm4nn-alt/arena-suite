# Journal format v1 (`ASJ1`)

Status: **design decision**, Phase 1. Implemented by `Packages/ArenaSuiteCore/Sources/CaptureJournal`.
Golden fixture: `Fixtures/Journal/golden-v1.asj` (checked by `JournalFormatTests`).

The journal is the authoritative evidence store (plan v3 §7). It is transport- and Arena-agnostic:
it stores opaque payload bytes plus a small JSON envelope, and knows nothing about Arena schemas.

## Directory layout

One journal per account, rooted at a directory chosen by the caller:

```text
<journal-root>/
  journal.lock                 advisory exclusive lock (flock) held by the single writer
  segments/
    000001.asj                 sealed segment (records)
    000001.seal.json           seal manifest for 000001
    000002.asj                 active segment (no seal manifest)
  quarantine/
    000002-0000004096.tail     bytes removed from a torn tail at offset 4096, preserved verbatim
```

- Permissions: every directory is `0700` and every file `0600`. The writer re-applies this on each
  open (so directories restored from backups are tightened) and refuses symlinks; failure blocks open.
- Quarantine names are `<segment>-<10-digit offset>.tail`; an identical existing file is reused, a
  different one gets a `-2`, `-3`, … suffix, so an interrupted recovery never duplicates evidence.
- Segment numbers are 6-digit, zero-padded, starting at `000001`, strictly increasing, no gaps.
- At most one segment is unsealed: the one with the highest number.
- A segment is created lazily on the first append after open/rotation. An empty active segment
  is deleted on orderly close.

## Record layout

All integers little-endian. One record:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `41 53 4A 31` (`ASJ1`) |
| 4 | 4 | `envelope_length` (UInt32) |
| 8 | 8 | `payload_length` (UInt64) |
| 16 | `envelope_length` | envelope: UTF-8 JSON object |
| 16 + E | `payload_length` | payload: opaque bytes, stored exactly as supplied |
| 16 + E + P | 32 | digest |

`digest = SHA-256( "ASJ1-record-v1" || 0x00 || bytes[4..<16] || envelope || payload )`

That is: a domain-separation string, a zero byte, the two length fields exactly as stored,
then the stored envelope and payload bytes. The hash covers **stored bytes**, never a
re-serialized envelope.

Limits (validated before any byte is written, and on read with overflow-checked arithmetic):

- `1 ≤ envelope_length ≤ 65 536`
- `0 ≤ payload_length ≤ 33 554 432` (32 MiB). Larger captures must be truncated by the caller and
  declared (`transfer_end: capture_limit`); the journal never truncates silently.

## Envelope

UTF-8 JSON object, keys sorted, no insignificant whitespace, `/` not escaped. Large integers are
JSON **strings** so non-Swift readers do not lose precision.

| Key | Type | Meaning |
|---|---|---|
| `format` | number | Envelope format, `1` |
| `record_id` | string | UUID, uppercase canonical form |
| `sequence` | string | Decimal UInt64. Assigned by the writer; starts at `1`, +1 per record, continuous across segments |
| `kind` | string | Caller-defined record kind (e.g. `exchange`, `job.started`, `job.finished`, `local.control`, `journal.recovered`) |
| `account_id` | string? | UUID of the local account, if any |
| `job_id` | string? | UUID of the job, if any |
| `observed_at` | string | UTC wall time, ISO 8601 with milliseconds, e.g. `2026-09-24T10:15:00.123Z` |
| `monotonic_ticks` | string? | Decimal `mach_continuous_time()` ticks at observation, if supplied |
| `payload_representation` | string? | Declared observation layer of the payload, e.g. `foundation_decoded_entity` |
| `transformations` | array of string | Declared transformations, e.g. `credential_omitted` |
| `metadata` | object | Caller metadata; values are string, integer (JSON number, Int64), bool, null, array, or object |

Absent optional keys are omitted, not written as `null`. Readers must ignore unknown keys
(forward compatibility) but must not rewrite them.

## Seal manifest (`NNNNNN.seal.json`)

Written atomically (temp file, sync, `rename`, directory sync; `F_FULLFSYNC` where supported under the default durability) **before** the next
segment is created.

```json
{"byte_size":"4096","first_sequence":"1","format":1,"last_sequence":"12","record_count":"12","segment":1,"sha256":"<hex of whole segment file>"}
```

A sealed segment is immutable. Its file hash must match `sha256`.

## Acknowledgement and durability

- `append` returns an `AppendReceipt` only after **every byte of the record** has been passed to
  the OS (partial writes completed, `EINTR` retried). This is the **appended** boundary: it
  survives process termination, not necessarily power loss.
- `synchronize()` issues `F_FULLFSYNC` (default) or `fsync` and reports the highest sequence it
  covers. This is the **synchronized** boundary.
- Consumers (decoders, index) read only appended records.
- After any write or sync error the writer enters a **failed** state and refuses further appends
  until the journal is reopened (which runs recovery). Errors carry `errno` and the operation.

## Recovery on open

1. Enforce permissions, then acquire `journal.lock` (non-blocking). If held, fail with `alreadyOpen`.
   Remove leftover `*.tmp` files in `segments/` and `quarantine/` (atomic writes that never reached
   their rename) and report them.
2. For every sealed segment: check file size and SHA-256 against its manifest. A mismatch is
   **corruption in a sealed segment**: open fails; nothing is repaired or skipped.
3. For the highest segment, if unsealed: parse records from offset 0. At the first invalid or
   incomplete record (bad magic, impossible length, short read, digest mismatch, sequence
   discontinuity), everything from that offset to end of file is the **torn tail**:
   - copy it verbatim into `quarantine/`, `fsync` it and the directory;
   - truncate the segment to the last valid record and `fsync` it;
   - after opening, append a `journal.recovered` record describing the quarantined range.
   Because recovery cannot find record boundaries after damage, valid-looking records after
   the first invalid one are preserved in the quarantine file, not re-admitted.
4. A lower-numbered segment without a seal manifest (should not happen; rotation seals first)
   is verified record-by-record; if entirely valid it is sealed as a recovery action and
   reported, otherwise open fails as corruption.
5. The next sequence continues from the last valid record.

The recovery report also lists **unterminated jobs**: `job_id`s with a `job.started` record and
no later `job.finished` record. Higher layers treat them as `interrupted`.

## Records whose body is a separate file

A record may keep its body outside the journal, in the account's content-addressed object store
beside it (`<account>/objects/sha256/<hex>` next to `<account>/journal`; folders `0700`, files
`0600`, each file named by the lowercase hex SHA-256 of its bytes; `CaptureJournal.ObjectStore`).
Such a record:

- declares `payload_representation` `object_reference` and has an empty payload;
- names the file in its metadata: `object_sha256` (64 lowercase hex characters) and `object_size`
  (integer, bytes).

The file is written (temporary file, sync, rename, directory sync) before the record is appended,
so a record never names a file that was not durably in place. A file without a record (the writer
stopped in between) is ignored: nothing names it. The record's digest covers the name and size,
not the file. `JournalVerifier` doesn't read the store; the app's Verify checks each named file
against its name and size, and backups (`arena-suite-backup/2`) copy and check every named file.
First user: `attachment.download` records (`Docs/attachments-2026-10-20.md`).

## Declared transformations in use

- `credential_omitted`: session material (`Set-Cookie` values, sign-in passwords) is not recorded.
- `signed_query_omitted`: an `attachment.download` record doesn't repeat the link's signed query, and
  a redirect's `Location`/`Content-Location` query is replaced by `[omitted]`.
- `token_omitted`: an `agent_detail` exchange's body has every JWT-shaped string (`eyJ…`, three
  dot-separated base64url segments of at least 8 bytes each) replaced by the 9 bytes `[omitted]`;
  metadata `tokens_omitted` gives the count. Every other byte is exact
  (`Docs/agent-detail-2026-10-21.md`).

## Verification

`JournalVerifier` is read-only. It checks every record's structure and digest, sequence
continuity, seal manifests, and reports a torn tail as an issue without modifying anything.

## Compatibility

A future format uses a new magic (`ASJ2`) in new segments; v1 segments are never rewritten
in place. A reader that meets an unknown magic reports it and refuses to write.
