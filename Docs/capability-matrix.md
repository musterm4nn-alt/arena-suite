# Phase 0 capability matrix

All **production adapter** capabilities remain unknown, with no adapter validation time or native
raw fixture. The executable inventory in `ArenaAdapter/Capabilities.swift` is unchanged. The
disposable proof's scoped results below do not represent an implemented production adapter.

Partial browser evidence B-001/B-002 and public-source evidence S-001 are now documented in
`browser-auth-observation-2026-09-21.md`. They do not establish native support; this matrix
continues to use native capability validation, not browser success, as its promotion boundary.
N-002/N-003 subsequently demonstrate native email/password login and stable identity recheck for
one manual session, recorded as user-supplied UI screenshot evidence. Their limited scope does not
prove refresh, restoration, a second account or chat, and no raw native response fixture exists.

| Capability | Production adapter state | Evidence/next step |
|---|---|---|
| authenticate | unknown | N-002: disposable native login observed; remaining Q01–Q03 contracts/fixture gate |
| refreshSession | unknown | Q01–Q04 |
| verifyIdentity | unknown | N-003: two ID claims stable within native session; browser equality/Q04 still open |
| createConversation | unknown | R-001 lead; Q05, Q08 |
| sendPrompt | unknown | R-001 lead; Q03, Q05, Q08, Q11 |
| streamResponse | unknown | R-001 lead; Q06–Q08, Q12–Q13 |
| stopRemoteGeneration | unknown | Q09, Q12 |
| listHistory | unknown | R-001 lead; Q16 |
| getHistoryDetail | unknown | R-001 lead; Q08, Q13, Q16–Q17 |
| continueConversation | unknown | R-001 lead; Q01, Q08, Q16 |
| uploadAttachment | unknown | Q17 |
| downloadWorkspace | unknown | Q17–Q18 |
| revealModels | unknown | Q14–Q15 |

Modes/modalities remain extensible provider strings when observed; no mode availability is claimed.
No fake adapter implementation returns a successful send or authentication result.
