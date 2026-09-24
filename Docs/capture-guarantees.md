# Capture guarantees at the end of offline Phase 0

**No production capture or durability is implemented.** No prompts are sent to Arena, no
archive is created, and no transcript is represented as saved. The native shell reports pending
feasibility. Research probes retain only small known synthetic responses in memory.

Verified locally: opaque fixture bytes round-trip across every split, one-byte/whole partitions
and 200 seeded partitions; invalid UTF-8 and incomplete bytes survive without semantic parsing.
HTTP delivered entity bytes match the scripted source for fragmented/gzip/chunked responses.
Callback units have contiguous offsets and monotonic entry ticks. Server writes need not map
one-to-one to Foundation callbacks. WS text is transport-delivered text, not original frame bytes.

Future contract: record before interpreting; durable raw append acknowledgement and sync boundary
must be separate; unknown protocol data survives; credential omission is explicit; auth-only
secrets stay out of ordinary evidence. In-flight account ownership is frozen. Unknown outcome
is not completion. Parser/storage failures cannot quietly erase admitted evidence.

Sanitized captures are transformed evidence, with mappings/reasons. Synthetic fixtures establish
local mechanisms only. They prove neither Arena grammar nor full source coverage. See
`fixture-format.md`, `transport-results.md`, and ADRs 0002–0004.
