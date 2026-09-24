# Authorized sanitized captures

Two sanitized authorized browser response captures are available: `direct-create.fixture.json`
and `direct-continue.fixture.json`. They contain complete-body observations of harmless research
prompts, not original callback boundaries. Metadata values were omitted and JSON rows reserialized;
they are transformed fixtures, not raw-exact protocol evidence. No request token or private ID is included.

Use `Docs/fixture-format.md` and `Docs/phase-0.md` when adding an authorized, manually reviewed capture.

`history-list.fixture.json` adds H-001's structural projection: all entry positions retained,
IDs pseudonymized, only id/type retained per entry, non-evaluation type values omitted, and
observed pagination/partiality retained. It is a subset, not a complete response or a raw capture.
Name accepted manifests `*.fixture.json`. A sanitized capture never proves byte identity with its private source.
