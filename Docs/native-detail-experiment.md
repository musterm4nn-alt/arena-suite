# Phase 0 native conversation-detail experiment

Preconditions: N-005/N-006 demonstrated one-account listing and same-build native restoration.
H-002 observed the official GET `/api/evaluation/[id]` contract. Generation stays disabled.

Acceptance: after identity verification, fetch a fresh observed history-list page and select its
first entry explicitly typed `evaluation`. Issue one detail GET; retain both raw replies before
optional structure inspection. Summarize HTTP/transport/byte count, list partiality, detail ID
equality, message session ID equality, message/duplicate counts and references outside the response.
No private ID, title, content, model name or server error text enters the diagnostic summary.

Scope: disposable research tooling, not a general graph parser or production history importer.
Outside-response references are counted, not automatically considered corruption. No semantic
terminal, content equality, ownership-field meaning, or continuation success is inferred.
Only path-safe opaque IDs with ASCII letters/digits/hyphen/underscore (up to 256 bytes) can be
addressed by this narrow recipe; all other representations remain unsupported without rewriting.
Unsupported list shape, failed/incomplete response or no eligible entry causes no detail request.
Unknown response fields remain in the retained private bytes. No pagination or generation occurs.

The automatic startup/sign-in workflow first performs the existing list observation, then this
separate identity + fresh-list + one-detail experiment. Thus two first-page GETs may occur per
run; neither is a retry or page traversal. The latest report uses `detailObserved`, which means
an observation exists, not that all semantic checks passed. Read its HTTP/transport and match flags.
Captured bytes are bounded and memory-only; the report is not a raw fixture.

Tests cover observed selection and GET recipe, unsafe IDs, identity mismatch before list dispatch,
unknown bytes, ID/session mismatch, duplicates and outside-response references.

Result: the reviewed build's value-free report was inspected on 2026-09-24. Acceptance met — list
page and one detail GET both HTTP 200 with complete transport, detail ID and message session IDs
match the selected list entry, no duplicate or outside-response references. Recorded as N-007 in
[native-detail-observation-2026-09-24.md](native-detail-observation-2026-09-24.md); the raw bytes
stayed in memory, so a detail fixture (A8) remains pending.
