# ADR 0004 — Account snapshots and observation clocks

Status: accepted design decision; minimal value snapshots implemented.

An operation holds immutable account UUID, optional opaque principal claim with provenance,
and credential generation. A principal claim is not itself authentication proof. Profile
acceptance requires observed server identity; mismatch must quarantine results in the eventual
coordinator. UI selection is not transport ownership and cannot rebind/cancel existing work.
No raw credentials are present in these DTOs. Remote IDs will be opaque and scope-qualified;
turns and attempts remain distinct when introduced.

The local probe samples `mach_continuous_time` at callback entry solely to check monotonic
ordering. It does not serialize portable elapsed times or claim model-token timing. Phase 1
adds clock/session/timebase/wall-anchor types and checked conversions. Fixture clocks explicitly
declare their units and synthetic status; no missing wall timestamps are fabricated.
