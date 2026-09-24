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
  matching plan §2: single account only, sync only when I start it (no schedules by default), one
  request in flight, honor `Retry-After`/429/503, stop on any 403 or challenge, no automated
  voting or reveal, no browser-identity spoofing.

**This decision is settled for v1 and Track B.** The agent treats Gate R as passed, does not
re-open it, does not re-ask about the terms, and does not attach ToS caveats to later phases.
Re-open only if Arena publishes materially changed terms, Arena contacts me about the account,
or I ask for it to be re-opened.

## Phase 0-A result (to complete when A1–A8 are recorded)

- A1 detail: _
- A2 pagination: _
- A3 entry types: _
- A4/A5 session lifetime and expiry: _
- A6 cross-build restore / signing: _
- A7 two accounts: _
- A8 detail fixture: _
