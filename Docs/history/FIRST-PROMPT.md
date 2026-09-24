# First implementation session: establish the Arena Suite Phase 0 foundation

You are the primary implementation agent for Arena Suite.

Before editing anything:

1. Read `AGENTS.md`.
2. Load the `arena-suite` skill.
3. Read `Arena-Suite-Master-Plan-v2.md`, especially:
   - executive architecture;
   - Arena communication/feasibility sequence;
   - authentication/account isolation;
   - adapter contract;
   - capture invariants;
   - testing strategy;
   - implementation sequence.
4. Inspect the entire current repository and Git status.
5. Verify the local toolchain and build/test paths.
6. Prefer XcodeBuildMCP for structured Xcode operations when useful.
7. Use Context7 for version-sensitive third-party/API documentation.
8. Do not assume any Arena endpoint, login mechanism, field, stream grammar, or terminal marker that has not been verified.

Your objective is **not to build the full application**.

Establish the repository and Phase 0 foundation required to safely prove or disprove the direct-native-client architecture.

At minimum address:

- repository/package/module structure consistent with the master plan;
- minimal compilable native macOS application/engine skeleton where appropriate;
- protocol-evidence types distinguishing:
  - verified observation;
  - repository evidence;
  - design decision;
  - assumption;
  - `NEEDS PROTOCOL VERIFICATION`;
- endpoint/protocol ledger format;
- immutable operation account-context types;
- Arena adapter capability states:
  - `supported`;
  - `unsupported`;
  - `unknown`;
- journal abstractions/tests only if the master-plan sequence places them in this phase;
- sanitized fixture/test infrastructure;
- Phase 0 verification checklist covering:
  - authentication;
  - identity;
  - create;
  - send;
  - stream;
  - stop;
  - history;
  - continuation;
  - relaunch;
  - two-account isolation;
- exact documentation of live actions/evidence I must provide.

Constraints:

- No production WebView/browser transport fallback.
- Browser developer tools may be used only as an authorized research instrument.
- No CAPTCHA/anti-abuse bypass.
- No guessed endpoints.
- No credentials/session cookies/bearer tokens/CSRF/private payloads in Git.
- Do not build large UI/archive/MCP surfaces before feasibility is proven.
- Keep changes small and reviewable.
- Run relevant builds/tests after each coherent slice.
- Do not push.
- Before declaring completion, invoke the `reviewer` subagent.
- Fix Critical/High findings and any Medium finding that threatens Phase 0 correctness.

If live authenticated observations are required but unavailable, do not fabricate them.

Complete every offline-safe part of Phase 0 and clearly identify the exact point where live verification is required.

At the end report:

1. what you implemented;
2. build/test results;
3. reviewer findings and fixes;
4. current Phase 0 gate status;
5. exact next live verification action;
6. all remaining `NEEDS PROTOCOL VERIFICATION` items.
