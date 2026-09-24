# Capture guarantees

Updated 2026-09-24, end of Phase 1. Nothing is captured from Arena by the product yet; these are
the guarantees of the `CaptureJournal` module that later phases write through.

**Appended** (an `AppendReceipt` was returned): every byte of the record was handed to the OS.
The record survives the app being killed at any point afterwards. Verified by the SIGKILL crash
gate (`Tools/CrashHarness`) at each write boundary: before the header, envelope, payload and digest,
in the middle of the payload, after the append, after a sync, and during segment sealing.

**Synchronized** (`synchronize()` returned): `F_FULLFSYNC` succeeded for the active segment
(`fsync` fallback, or `fsync` in test configurations). Protection against power loss is only as
good as the storage device honoring that call; it has not been tested with real power loss.

**Not guaranteed:** records whose append did not return; exact reconstruction of network wire
bytes (payloads are what Foundation delivered); protection against deliberate rewriting of the
whole journal (digests detect damage, not tampering).

**On damage:**
- A torn or corrupt tail in the active segment is copied verbatim to `quarantine/` before
  truncation, and a `journal.recovered` record is appended.
- Corruption inside a sealed segment blocks opening and changes nothing.
- An unknown format version is refused, not quarantined.
- A write or sync error (e.g. `ENOSPC`, `EIO`) stops the writer until it is reopened.

Unknown protocol data survives because payloads are opaque to the journal; interpretation happens
in later phases, and never modifies journal bytes. Credential values never enter records; exchanges
declare a `credential_omitted` transformation (enforced in Phase 3, where exchanges are recorded).
