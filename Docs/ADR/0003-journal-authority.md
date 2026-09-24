# ADR 0003 — Journal authority; implementation deferred to Phase 1

Status: accepted design decision; not implemented.

Append-only raw/control journal is authoritative; SQLite, manifests and normalized views are
rebuildable projections. Record before interpret. Observed, appended, synchronized, projected
are distinct watermarks; never call an in-memory observation durable.

Phase 0 research fixture JSON is neither ASJ1 nor an archive. Exact widths, hashing, framing,
I/O failure/recovery behavior, golden binary fixture and crash harness are Phase 1 work after
the capture contract passes. Do not fossilize a journal format to make Phase 0 appear complete.
