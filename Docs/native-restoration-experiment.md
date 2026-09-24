# Phase 0 native session restoration and automatic checks

The user explicitly authorized Keychain-backed session cookies and automatic read-only checks
on 2026-09-22, to avoid repeated manual sign-in and status screenshots. Generation remains on hold.
This is a disposable one-slot experiment under master-plan section 4's native session rules,
not the Phase 4 multi-account registry or a refresh implementation.

## Acceptance criteria

- Save native cookie properties and both verified identity claims only in a dedicated generic
  password Keychain item. Never save the password or export cookies into the evidence archive.
- On launch, load into an empty ephemeral cookie jar, then verify `/api/me` against both saved
  IDs. Missing/corrupt/expired/mismatched state cannot trigger a history fetch. No silent fallback
  to a different logged-in principal. Failure requires manual sign-in.
- Following verified restoration or manual sign-in, execute the observed history-list GET once.
  No automatic paging, generation, challenge acquisition or retry. Following N-005/N-006, the
  next research increment adds the separate bounded detail experiment in `native-detail-experiment.md`.
- Write only a value-free status summary, time and random run ID to
  `DerivedData/NativeProofResult.json` beside the bundled app. `DerivedData` is ignored by Git.
  This file is a diagnostic, not a credential store, protocol fixture or authoritative capture.
- Provide **Forget Saved Session** to remove the Keychain item and discard the active session.

## Credential boundary

Fixed Keychain service `ArenaSuite.NativeAuthProof.Session.v1`, account `single-research-session`.
Item is non-synchronizing, `WhenUnlockedThisDeviceOnly`; macOS controls access and may prompt.
The app is locally ad-hoc signed, so access prompts across rebuilds remain a live feasibility issue.
Neither Keychain authorization nor credential values are transferred through automation/chat.

Versioned JSON inside the Keychain item contains principal IDs and binary-plist cookie properties.
Foundation cookie properties preserve domain/path/expiry/security flags; no manual Set-Cookie parsing.
Only observed Arena host/root-domain cookies are admitted. Import into a nonempty jar is rejected.
The decoder caps record/cookie sizes and rejects unsupported versions and foreign domains.
No claim of secure memory zeroization. Active sessions remain in process memory.

One saved slot is intentional: a later successful manual sign-in replaces that slot. **New Isolated
Session** only clears active process state; **Forget Saved Session** also deletes the saved item.
This is not proof of multi-account persistence or actual two-account isolation. No refresh route
has been invented. Expiration requires manual sign-in rather than replaying a password.

## Verification

Synthetic tests cover save/restore with identity verification, either ID mismatch, malformed/missing
state, password exclusion, expiry rejection, cookie property round-trip, rejected foreign domains,
and restoration into isolated fresh Foundation jars. Unit tests use an in-memory store, never the
user's Keychain item. Initially, real Keychain save and relaunch remained pending; N-005/N-006 below
supersede that initial status for one account in the same build.
The app can run subsequent read-only checks itself after one successful manual sign-in.

N-005/N-006 now demonstrate native save and same-build quit/relaunch restoration with history
listing for one account. See `native-history-restoration-2026-09-24.md`. Cross-build access,
expiry/refresh, live forgetting and two-account behavior remain pending.
