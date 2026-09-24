# Arena Suite — Phase 0 foundation

Native ARM64 macOS client feasibility research. **Initial native login/identity succeeded in a
manual proof; native generation is on hold after a reCAPTCHA rejection. The full Phase 0 gate
remains incomplete.** The product app shows only an offline feasibility status; network experiments
live in the separate disposable research executable.

Canonical specification: [`Arena-Suite-Master-Plan-v3.md`](Arena-Suite-Master-Plan-v3.md).
Session plan, acceptance criteria, and live handoff: [`Docs/phase-0.md`](Docs/phase-0.md).

Authorized browser login/identity research is now recorded in
[`Docs/browser-auth-observation-2026-09-21.md`](Docs/browser-auth-observation-2026-09-21.md).
The separate, disposable [native authentication proof](Tools/NativeAuthProof/README.md)
has a successful single-session manual login/identity result. Production adapter capabilities
remain unknown pending their own contracts/fixture validation; this is not a product authentication implementation.
The proof now includes an identity-checked, read-only history probe and a user-authorized
[Keychain restoration experiment](Docs/native-restoration-experiment.md). Restoration and native
history now have a successful one-account, same-build live observation (N-005/N-006); broader
refresh/isolation gates remain open and generation is disabled. Automated status contains no
credentials or conversation contents and is written to ignored `DerivedData/NativeProofResult.json`.

```sh
bash Scripts/test-offline.sh
bash Scripts/build.sh Debug
bash Scripts/build.sh Release
open DerivedData/Build/Products/Debug/ArenaSuite.app
```

Full Xcode, ARM64 macOS, and Python 3 are required. macOS deployment floor is 14.0;
runtime verification so far is only on the host in `Config/toolchain.json`.
Tests use synthetic loopback traffic and declared sanitized fixtures; they require no Arena access. Package unit tests are
Swift Testing (the XCTest wrapper's “0 tests” line does not represent their count).

Optional dependency compatibility probe (initial resolution needs public GitHub access):

```sh
swift run --package-path Tools/DependencyProbe --force-resolved-versions DependencyProbe
```

This standalone probe pins later-phase GRDB/MCP dependencies without linking them into the app.
It is a build/SQLite diagnostic check, not MCP conformance certification.

## Current boundaries

- `Packages/ArenaSuiteCore`: Foundation-only `SuiteDomain` values and minimal `ApplicationActions` engine actor.
- `Packages/ArenaProtocol`: capability contract/inventory, with every Arena operation unknown.
- `App`: SwiftUI shell consuming the semantic application boundary.
- `Tools/FixtureHarness`: loopback transport experiment and research-fixture validator.
- `Fixtures`: synthetic bytes and explicitly transformed browser generation/history-list captures.
- `Docs`: ledger, ADRs, measured capture limits, and verification checklist.

`Scripts/check-boundaries.py` checks current production imports; register new modules explicitly.
Later journal/parser/archive/MCP targets are introduced only at their milestones. Credentials,
private captures, local OpenCode configuration/backups, and build products are ignored.
Private originals belong outside this repository, even though accidental capture extensions are ignored.
