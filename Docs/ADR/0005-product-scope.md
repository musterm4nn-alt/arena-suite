# ADR 0005 — Product scope after Phase 0

Status: **accepted** (Gate R decided 2026-09-24; Phase 0-A result still open pending A1–A8).

## Context

Phase 0 showed that native sign-in, identity verification, Keychain session restore and history listing
work (N-002/N-003, N-005/N-006). Native generation was rejected by reCAPTCHA v3 validation (N-004).
Plan v3 §1 therefore defines v1 as a read-only native archiver and moves generation to a
conditional Track B.

## Decision

- v1 = read-only archiver: sign in, sync history, journal, index, browse/search, export.
- Track B (generation, plus manual user-clicked vote/reveal) is **blocked** by N-004 and starts only
  under plan §1's conditions.
- No browser runtime, browser-token transfer or challenge bypass in any version.
  *Amended 2026-10-18 (ADR 0006):* the one allowed browser runtime is the visible, user-driven
  arena.ai window. Browser-token transfer and challenge bypass remain excluded in every version.
- Traffic policy per plan §2.

## Gate R — terms of use and account risk (user decision recorded)

The agent does not interpret Arena's terms for the user. This section records the user's own
decision, made after reading them.

- Terms reviewed on (date): 24.09.2026
- Terms version/URL as read: `https://arena.ai/terms-of-use` — "Arena: Terms of Use Agreement",
  Arena Intelligence, Inc., Last Updated 2026-02-23
- Is a third-party native client that reads the user's own history acceptable to you in light of those terms?
  **Yes.** The terms restrict accessing the Service through programmatic or automated means and
  scraping/extracting data (User Conduct and Certain Restrictions, items vi and vii), and they let
  Arena suspend or terminate an account for any or no reason. I read those clauses before deciding.
  A read-only client that syncs only my own account's history is acceptable **to me** at my own risk;
  I do not need the terms to permit it, and this record does not claim they do.
- Accepted risk (e.g. account suspension) and any limits you want:
  **I accept that Arena may suspend or terminate the account, including because of this client, and
  that I would then lose the account (already-archived conversations stay local).** Limits I want,
  matching plan §2: ~~single account only~~ **multiple accounts, each fully isolated (changed by the user on 2026-09-24, after the A7 question)**, sync only when I start it (no schedules by default), one
  request in flight, honor `Retry-After`/429/503, stop on any 403 or challenge, no automated
  voting or reveal, no browser-identity spoofing.

**This decision is settled for v1 and Track B.** The agent treats Gate R as passed, does not
re-open it, does not re-ask about the terms, and does not attach ToS caveats to later phases.
Re-open only if Arena publishes materially changed terms, Arena contacts me about the account,
or I ask for it to be re-opened.

## Phase 0-A result (to complete when A1–A8 are recorded)

- A1 detail: **Verified (N-007, 2026-09-24).** One fresh observed history-list page → first
  `evaluation` entry → one GET `/api/evaluation/{id}`: HTTP 200, complete transport, 49084 bytes;
  detail ID equals the selected list entry; message session IDs match; 3 messages; 0 duplicate
  message IDs; 0 parent and 0 last-message references outside the response. No continuation, no
  pagination, no generation. One account, one build, one request each. See
  `Docs/native-detail-observation-2026-09-24.md`. The detail fixture (A8) is still pending.
- A2 pagination: **Verified (N-008).** `cursor=<pagination.cursor>`; pages 5/5/4, no overlap, union equals the full list.
- A3 entry types: **Observed (N-008):** `evaluation`, `agentic` (no archived entries). Accepted limitation: `agentic` archived as list entries only until a detail route is observed.
- A4/A5 session lifetime and expiry: **A5 verified** (no session → 401 JSON). **A4 partly:** auth cookies expire 2027-10, re-issued on some request (not `/api/me`); ≥24 h behaviour pending.
- A6 cross-build restore / signing: **Verified (N-009)** with the Apple Development identity, once the item is created by a signed build.
- A7 two accounts: **Verified (N-010)** in one process: distinct principals, 0 shared entries, 0 shared cookie values.
- A8 detail fixture: **Done** — `Fixtures/SanitizedArena/native-detail.fixture.json` (metadata telemetry masked).

## Decision 2026-09-24 — Keychain storage

Keep the legacy login Keychain for session material in v1 (user decision). Items are readable
without a prompt only by apps with the same code-signing identity and are not synchronized, but
they are not device-bound (the login Keychain ignores `kSecAttrAccessible`). Moving to the
data-protection Keychain would require a keychain-access-group entitlement and provisioning profile.
