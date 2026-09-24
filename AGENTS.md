# Arena Suite — Repository Instructions

`Arena-Suite-Master-Plan-v3.md` is the canonical architecture and implementation specification for this repository. `Arena-Suite-Master-Plan-v2.md` is superseded and kept only as historical reference; where they conflict, v3 wins.

## Working rule

Do not treat the task as “build the whole app.” Work phase-by-phase (v3 §13). Before implementing a milestone:

1. Read the relevant sections of `Arena-Suite-Master-Plan-v3.md`.
2. Load the `arena-suite` skill.
3. Inspect the existing repository and tests.
4. State the milestone's concrete acceptance criteria.
5. Implement only what is required to satisfy those criteria.
6. Build and run the relevant tests.
7. Use the `reviewer` subagent at the end of each phase, and on any change touching credentials, Keychain, journal format, or recovery.
8. Fix correctness findings before moving to the next milestone.

If the canonical plan is absent, do not invent a substitute architecture.

## Architectural invariants

- v1 is a native, read-only Arena archiver (sign in, sync history, browse, search, export). It does not send prompts, vote, reveal models, or upload files.
- Native generation is Track B: blocked (reCAPTCHA v3, N-004) and started only under v3 §1's conditions. Voting/reveal belong to Track B as manual, user-clicked actions only — never automated or exposed to MCP.
- No WebView/browser runtime in the product, no browser-token transfer, no CAPTCHA or anti-abuse bypass.
- Follow the v3 §2 traffic policy: user-initiated sync, one request in flight per account, honor rate limits, stop on 403/challenge.
- Record before interpret.
- The append-only raw journal is authoritative. SQLite and normalized projections are rebuildable.
- Never silently discard, normalize away, or reinterpret unknown protocol evidence.
- Credentials are a narrow declared exception to exact capture; reusable authentication secrets do not enter the ordinary evidence archive.
- Account context is immutable once an operation starts.
- Changing the selected UI account must not redirect or cancel unrelated in-flight work.
- Preserve conflicting model-identity claims with provenance.
- "Complete" always names its scope (e.g. "observed pagination").
- Timing claims must name the observation boundary actually measured.
- Views go through ApplicationActions; only ArenaAdapter knows Arena routes.
- Protocol drift must degrade safely.

## Engineering behavior

- Prefer small, reviewable changes over broad rewrites.
- Do not invent Arena endpoints, fields, terminal markers, IDs, or authentication semantics.
- Mark unverified protocol assumptions explicitly and back them with fixtures or an endpoint ledger.
- Use Swift 6 concurrency deliberately.
- Keep authoritative writes recoverable independently of SQLite.
- Keep raw byte capture out of logs.
- Add tests with every protocol parser, journal-format, migration, recovery, or permission change.
- For decoder work, test unknown fields, unknown entry types, and malformed/truncated bodies.
- For durability/recovery work, test real process termination and I/O failure paths where practical.

## Tools

- Prefer XcodeBuildMCP for structured Xcode project/build/test operations when available.
- Use ordinary `xcodebuild`/`swift test` when clearer or when MCP is unavailable.
- Use Context7 for current third-party/API documentation when version-sensitive details matter.
- Do not add new MCP servers or dependencies merely for convenience.

## Git safety

Do not push, force-reset, clean the worktree, rewrite history, or perform destructive repository operations unless the user explicitly asks.

Commit with the user's configured Git identity. The reviewer subagent runs one shell command per call (no `;` or `&&` chains) and states whether it saw the real diff and ran tests.
