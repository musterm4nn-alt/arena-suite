# H-001 / H-002 — read-only browser history research

Scope: remaining Phase 0 work, authorized by the user after putting N-004 generation on hold.
Observed 2026-09-22, with relationship checks at 13:42:48.989Z. Browser version was not recorded.
The research browser's previous controller memory had reset; a new passive collector was installed.
No generation, vote, archive, deletion, or other mutation was submitted.

## H-001: list

Official navigation issued GET `https://arena.ai/api/history/unified?limit=20&includeArchived=false`.
HTTP 200; complete Playwright-decoded body 3857 bytes, retained transiently in private controller
memory. Top-level fields: `entries`, `pagination`, `partial`, `failedSources`.
Observed 11 entries, `pagination.hasMore=false`, `pagination.cursor=null`, `pagination.limit=20`,
`partial=false`, empty `failedSources`. No nonempty cursor or failed-source element grammar verified.
Entry field names observed: `type`, `id`, `title`, `createdAt`, `updatedAt`, `mode`, `modality`,
`modelAId`, `modelBId`, `modelAOrganization`, `modelBOrganization`, `archivedAt`.
Private values and other conversations' content are excluded from these notes.

The prior synthetic research conversation appeared in the list and had one official `/c/[id]`
link. Its type was `evaluation`, mode `direct-battle`, modality `chat`.

## H-002: detail

Clicking that observed link produced GET `/c/[id]?_rsc=…` (HTTP 200, `text/x-component`, 4007 bytes)
and GET `https://arena.ai/api/evaluation/[id]` (HTTP 200, `application/json`, 21140 bytes).
No endpoint was inferred from naming alone. Raw bodies stayed in private controller memory.
Detail `id` matched the selected list ID; all four messages' `evaluationSessionId` matched it.
All four contents matched the known synthetic research prompts/answers, with roles/statuses:

| Local observation alias | Role | Status | Parent aliases |
|---|---|---|---|
| message-1 | user | success | none |
| message-2 | assistant | success | message-1 |
| message-3 | user | success | message-2 |
| message-4 | assistant | success | message-3 |

`lastMessageIds` mapped to message-4. Each message had zero attachments. Both expected answers
were visible in the official UI. This verifies relationships in this retrieved browser response;
it does not recover the unavailable original request-ID comparison in C-001/C-002.

Detail also exposed profile/metadata/model claims and feedback arrays. Only field shapes were
inspected; values were not exported. Such claims are not independent backend identity evidence.
The initial observation had no portable fixture. Subsequent export produced
`Fixtures/SanitizedArena/history-list.fixture.json`: an allowlisted projected subset with
pseudonyms and the original body hash. Omitted fields and reserialization are declared. It is not
a raw-exact or full-response fixture. No general history grammar, pagination completeness, or
native access is claimed. Detail still has no portable fixture.

## Next native experiment

Acceptance: verified same-session identity before one read-only list GET; fixed observed query;
record response bytes before inspecting a minimal shape; show only counts/status; unknown or
interrupted responses remain unverified with original bytes retained. No automatic pagination or
detail request. Tests use explicitly synthetic bodies and include unknown fields, partial pages,
either identity claim changing, malformed/rejected/interrupted responses, and no private summary text.
The empty observed failedSources array establishes no element contract; a string array is only a
provisional inspection shape. Other element shapes produce an unverified summary, retaining bytes.
Native detail and a portable sanitized detail fixture remain follow-up work after list feasibility.
Generation is held; the proof UI disables its button. No production capability changes.
