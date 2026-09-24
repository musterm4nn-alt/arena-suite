# N-005 / N-006 — native history and relaunch restoration

Scope: one account, reviewed proof build from commit `ce6c82e`, direct native Foundation transport.
Generation remained disabled. No browser state or password was extracted by the agent.

## N-005 — manual sign-in followed by automatic history

Fresh app run reported `awaitingLogin` at 2026-09-24T07:33:33Z. The user then confirmed manual
sign-in. At 07:34:27Z the value-free report advanced to `historyObserved`:

- HTTP 200; transport complete; 4811 response bytes.
- 14 entries; `hasMore=false`; `partial=false`; zero failed sources.
- No further page requested.

The reviewed automatic flow saves native cookies and expected ID claims in Keychain before
dispatching its identity-checked history request. Successful advancement supports a successful
Keychain write in this run. This is an app diagnostic backed by reviewed code, not a raw fixture.

## N-006 — quit, fresh process, verified restoration

The agent requested normal app termination via its bundle ID. A process check found no matching
proof executable. The agent launched the same app again; no manual login was submitted.
At 07:35:22Z a different run ID reported `historyObserved`, with HTTP 200, complete transport,
4811 bytes and the same count/partiality summary as N-005.

The reviewed startup path loads Keychain cookies into a fresh ephemeral jar, verifies both saved
ID claims against `/api/me`, resaves session state, then performs the separate identity-checked
history GET. Therefore this demonstrates successful native one-account relaunch restoration and
read-only history-list access in this build. No private IDs, email, cookies or raw body are included.
Equal counts/byte sizes do not establish exact payload identity or a full history comparison.

## Remaining limits

- No production capability is promoted; Phase 0 remains incomplete and generation is on hold.
- Native detail retrieval, nonempty pagination, actual refresh/expiration, cross-build Keychain
  access, Forget Saved Session live verification and two-account isolation remain pending.
- This verifies history listing after relaunch, not conversation continuation after relaunch.
- Evidence is the fixed status report plus observed process lifecycle and reviewed code; no
  raw native history fixture was exported. Capture stays in memory, not a durable journal.
