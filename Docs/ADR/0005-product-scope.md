# ADR 0005 — Product scope after Phase 0

Status: **proposed**. Gate R (below) is pending the user's decision.

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

## Gate R — terms of use and account risk (user to complete)

The agent does not interpret Arena's terms for the user.

- Terms reviewed on (date): _
- Terms version/URL as read: _
- Is a third-party native client that reads the user's own history acceptable to you in light of those terms? _
- Accepted risk (e.g. account suspension) and any limits you want (single account only, manual sync only, …): _

## Phase 0-A result (to complete when A1–A8 are recorded)

- A1 detail: _
- A2 pagination: _
- A3 entry types: _
- A4/A5 session lifetime and expiry: _
- A6 cross-build restore / signing: _
- A7 two accounts: _
- A8 detail fixture: _
