# Research fixture format v1

`Tools/FixtureHarness/fixture_manifest.py` validates `arena-suite.fixture/1` manifests.
See `Fixtures/Synthetic/opaque.fixture.json` for a runnable synthetic example.
This is a research interchange format, not the Phase 1 authoritative journal format.

Required metadata: `id`, `scenario`, `source` (pinned generator or private source ID),
`provenance` (`synthetic`, `sanitized_capture`, `private_exact_capture`),
`observation_layer`, `clock` (units, clock identity, precision/unknowns),
`adapter_version`, `parser_version` (use `not_implemented` explicitly),
`expected_associations` (an array; empty means no interpretation claimed),
`fidelity`, `transformations`, `units`, and `stream_sha256`.

Each unit records a stream ID, contiguous exported byte offset, integer observation ticks,
base64 bytes, and SHA-256 of those bytes. Offsets/ticks describe the declared observation
boundary, not HTTP transfer chunks or model tokens. Keep different requests/directions in
different streams. Unknown bytes, invalid UTF-8, and incomplete tails remain representable.
This first validator handles contiguous per-stream captures; split gapped captures into
explicit scenarios and document the unobserved interval instead of fabricating continuity.

For sanitized captures set `fidelity=transformed`, include `authorization_reference`,
`review_reference`, and nonempty transformations containing `scope`, `reason`, `policy`,
and `mapping`. Mapping must explain original-to-export offsets/unit relationships and
any timestamp/identifier changes. Source references use opaque local IDs, not private paths.
Keep original hashes and restricted source mappings outside Git if they expose sensitive data.

Private originals live **outside the working tree** in a user-owned restricted directory.
An optional ignored root `private-fixtures.json` may map fixture IDs to absolute external
paths; it is a manual research inventory, never consumed by offline CI or uploaded.
Authentication bodies/secrets are excluded from ordinary capture even there. Keychain is
the eventual credential store; this harness has no credential input facility.

Before adding a capture, manually inspect reconstructed full streams, headers, URL query
values, signed URLs, filenames, tool arguments, and binary data. Remove reusable credentials
and private content from the copy; record each transformation. Never rely on per-chunk regex
scans or assume the metadata validator proves secret absence. Do not commit a raw HAR.
DevTools exports may omit raw boundaries/timing/bytes: label those unavailable, not exact.

Run `python3 Tools/FixtureHarness/fixture_manifest.py` and
`python3 Tools/FixtureHarness/test_manifest.py`. The partition test establishes byte
reassembly only; semantic parser/chunk-invariance tests belong to Phase 2.
