# Foundation observation-boundary experiment

Measured 2026-09-20 on `Config/toolchain.json` host, using
`python3 Tools/FixtureHarness/run_transport.py`. Synthetic HTTP/1.1 and RFC 6455 bytes
are written by a loopback-only raw Python server; its exact scripted output is the lower-level
reference, not a browser or TLS capture. Swift probe uses URLSession data delegate on a serial
OperationQueue. No Arena URL/credential input is accepted.

| Test | Reference | Observed result / acceptance |
|---|---|---|
| Fragmentation | One-byte writes, UTF-8 scalar and CRLF boundaries, unfinished SSE-like tail | Exact entity reconstruction; this run coalesced into one callback; callback/write counts not equated |
| Compression | gzip entity, known uncompressed bytes | Foundation delivered decoded body; comparison passed; cannot claim original compressed entity bytes |
| Duplicate headers | Two `X-Probe` fields: first, second | `first, second` combined value; ordering/field-line fidelity not promised |
| Trailers | Chunked body, declared `X-Trailer: final` | Body matched; trailer absent from inspected completed HTTPURLResponse |
| Redirect credentials | Synthetic Cookie/Authorization/CSRF and cross-host redirect | Delegate refuses redirect; target receives zero requests; no claim about automatic Foundation stripping |
| Cookie isolation | A/B same-host same-name cookies on independent ephemeral configurations | Private jars distinct from each other/global store; concurrent requests returned A/B respectively; fresh session empty |
| WS fragmentation/control | Text split within UTF-8 with intervening ping, then binary | One assembled `café` string and exact binary message; no data API delivery of ping/frame fragmentation |
| WS configured message limit (2026-09-21) | `maximumMessageSize=1024`; binary messages of 512 and 2048 bytes, each split into 64-byte frames | 512 bytes reconstructed exactly; 2048 rejected with `NSPOSIXErrorDomain/EMSGSIZE` (40), never delivered as complete content; bounded by the 45-second outer probe deadline |

**Decision:** Foundation remains provisional for delivered-entity/message capture. It is inadequate
for exact duplicate header lines, original compression representation, trailers, or WS frame/control
fidelity through these APIs. Whether Arena requires those is **NEEDS PROTOCOL VERIFICATION Q07**.
Transport acceptance remains pending until live requirements are compared. These HTTP/1.1 findings
do not establish HTTP/2/3 behavior, TLS fingerprints, browser equivalence, backpressure guarantees,
production redirect policy, or macOS 14 runtime behavior.

The size-limit result establishes an assembled-message boundary even when every frame is below
the configured limit. This API does not expose the rejected message's partial frames as data
callbacks; larger required Arena messages could therefore demand a higher verified limit or a
different transport. No finite configured value is a universal losslessness guarantee. The probe
asserts the observed error on this host; a changed OS error must be investigated rather than
accepting any timeout/connection failure as proof of a size rejection. It does not measure a
separate maximum wire-frame size. Whether Arena uses WebSockets at all remains unknown.

Protocol/framer tests are intentionally absent until actual dialects and the journal boundary exist.
The synthetic SSE-like body is just bytes here; no Arena terminal marker is inferred from it.
