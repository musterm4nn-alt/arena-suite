# Agent conversations (2026-10-21)

Item 1 of the arena-exporter gap analysis (`Docs/arena-exporter-gaps-2026-10-19.md`). Until now,
`agentic` history entries were archived from the list only, because no detail route had been observed.

## Observation (ledger N-022)

`Tools/NativeAuthProof --agent-detail` restores the proof session and verifies its identity. It then
reads history pages until it finds an `agentic` entry and sends two GETs for it, one request at a
time, 1 s apart. The report (`DerivedData/AgentDetailResult-A.json`) holds statuses, sizes, counts
and key names only. The page itself stays in a git-ignored local file.

- `/api/evaluation/{id}` answers `404` for an agent conversation.
- `/agent/{id}` answers `200` with an HTML page. Its Next.js flight chunks hold one transcript object:
  - `messages[]` in the AI SDK's message format;
  - `pagination`, with up to 20 messages per page;
  - `transcriptReadStrategy` `bounded`;
  - `triggerAddress`, equal to the conversation ID;
  - a `session` with a `publicAccessToken` (a JWT).

## Acceptance criteria

1. Sync History fetches an `agentic` entry's `/agent/{id}` page when its `updatedAt` changed or it has
   no snapshot yet. Refresh fetches it again. Both follow the job's spacing and stop rules (plan §2).
2. The page is journaled before it is read, with every JWT-shaped string replaced by `[omitted]`. The
   record declares `token_omitted`, metadata `tokens_omitted` gives the count, and every other byte
   is kept.
3. A page counts as a snapshot only if its transcript's `triggerAddress` is the conversation's ID.
   Any other `200` page is a warning, and the job goes on. A `404` is recorded as absent. A page with
   Cloudflare's interstitial markers stops the job as blocked.
4. The decoder (`arena-decoder/4`, one index rebuild) turns the transcript into messages and blocks:
   - `text` → text;
   - `reasoning` → reasoning;
   - `tool-<name>` → a tool call with its `input`, plus a result when `output` is present;
   - any other part → an opaque block;
   - unknown keys are counted, `metadata` is not projected, and `step-start` is not projected
     because it carries nothing but its type.
5. A transcript whose `pagination.hasMore` is not `false` gets the warning `agent_transcript_partial`.
   Only the page's first page of messages is archived. Reading further pages isn't observed, so it
   isn't attempted.
6. The transcript shows the replies under "Agent". An agent conversation without a snapshot says that
   Sync History fetches it.

## Not done

- **Not projected:** model claims (the page names none), the conversation's mode (`productMode`), and
  per-message timestamps.
- **Not fetched:** later transcript pages, the realtime stream and workspace files
  (`workspace/latest`).
- **Unfinished replies:** messages still `pending` in `metadata` are not treated as unfinished, so a
  conversation synced mid-run is refreshed only when its `updatedAt` changes or the user refreshes it.

## Evidence

- **Real page check:** run locally on the saved page, without its token. 1 token blanked
  (246 462 → 246 058 bytes), page valid, 2 messages, reply blocks reasoning, text, tool call and
  result (`write_file`, `present_file`). 0 unknown fields, 0 warnings.
- **Tests:**
  - `AgentDetailTests` covers token blanking, transcript lookup, the decoder, and drift and partial
    pages.
  - `HistorySyncTests` covers fetching and the token-free record, replay with no refetch, Refresh,
    a 404, an unrecognized page, a page naming another conversation, and a challenge.
  - In the proof tool, `AgentDetailTests` covers the inspector.
