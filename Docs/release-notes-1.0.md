# Arena Suite 1.0.0 — release notes (personal release)

A native macOS archiver for your own Arena history: sign in, sync, browse, search, inspect raw
evidence, and export. It is read-only. It never sends prompts, votes, reveals models or uploads files.

## Install and upgrade

```sh
bash Scripts/package.sh        # Release build, signature check, install to ~/Applications/Arena Suite.app
```

- It needs the git-ignored `Config/Signing.local.xcconfig`. An ad-hoc build is refused because the
  Keychain would stop granting access to saved sessions after an upgrade (N-009).
- An upgrade replaces the app only after the new copy is complete and verified. It refuses while
  the app is running. The archive in `~/Library/Application Support/Arena Suite/Archive` is never
  touched.
- If the script is killed mid-swap, the previous app is kept in
  `~/Applications/.arena-suite-install.*/previous.app`.
- Checked on the target Mac (2026-09-24):
  - A clean install with an empty home folder creates an empty owner-only archive and starts with
    no accounts.
  - An upgrade over the development archive opened all 57 conversations, and 3 accounts restored
    their sessions without a Keychain prompt.

## What's in 1.0

- **Multiple isolated accounts.**
  - Each account has its own session, Keychain item and journal.
  - Sign-in is native: no browser, no WebView.
- **History sync.**
  - You start every sync yourself.
  - One request at a time per account, spaced at least 1 s apart.
  - A 403 or challenge page stops the job.
  - Sync is resumable and incremental.
- **Append-only journal.** Every HTTP exchange is recorded before it is interpreted. A crash never
  loses an acknowledged record.
- **Rebuildable index.**
  - Browse and full-text search work offline.
  - The transcript shows battle lanes, votes and model claims with their sources.
  - The evidence inspector shows the exact journal record behind any message.
- **Exports.**
  - Formats: Raw JSON, Normalized JSON and Markdown.
  - Output is deterministic, and files are owner-only.
  - Telemetry is masked unless you confirm exact bodies.
- **Maintenance** (sidebar → Maintenance…):
  - *Verify Archive*: checks every record digest, sequence continuity and seal manifest, then
    compares the index with a fresh replay of the journals. It never repairs anything.
  - *Rebuild Index*: recreates the index from the journals.
  - *Back Up…*: writes a new `Arena Suite Backup <date>` folder, then checks it.
    - Contents: every journal (sealed segments byte for byte, the active segment up to its last
      complete record) and the account list.
    - A manifest records SHA-256s and the index digest the journals replay to.
    - Not included: no passwords, cookies or sessions.
  - *Check Backup…*: re-hashes every file, rejects missing, extra or changed files, verifies the
    journals and replays them to the recorded digest.
  - *Restore from Backup…*: only offered while there are no accounts (a new Mac or a fresh
    install). It checks the backup, installs it, rebuilds the index and reloads the accounts.
  - *Save Diagnostics…*: a JSON report with versions, counts, journal health, HTTP status and
    outcome histograms, warning codes and unknown field paths.
    - Accounts appear as `account-1`, `account-2`, and so on.
    - It contains no message text, titles, IDs, names, emails, paths or bodies.

## Known limitations

- **Generation, voting and model reveal are not available.** Track B is blocked by reCAPTCHA v3
  (N-004).
- **`agentic` history entries are archived list-only.** No detail route has been observed for them.
- **Session lifetime past 24 h is not yet confirmed** (A4 pending). If a session expires, the
  account shows "Sign in again". Nothing is retried automatically.
- **Saved sessions use the legacy login Keychain.** The items are ACL-protected but not
  device-bound (a deliberate choice, Phase 2).
- **Backups:**
  - They exclude Keychain items: after restoring on another Mac, sign in to each account again.
  - They exclude `quarantine/` (torn tails cut off during crash recovery). Those bytes were never
    acknowledged records.
  - Restore only works into an empty archive. It never merges with or overwrites existing
    accounts.
  - Verify, Rebuild, Back Up and Restore run only while no sync is running, and no sync can start
    while they run (enforced in `HistorySyncService`). A backup is refused if accounts are added
    or removed while it runs.
  - The backup manifest is checked by hash but not signed. It protects against damage, not
    against someone deliberately rewriting a backup together with its manifest.
- **Journal damage:**
  - A damaged sealed segment is reported by *Verify Archive* but not repaired.
  - That account's index cannot be updated until the segment is replaced.
  - Manual fix: quit the app, then replace
    `Archive/accounts/<id>/journal/segments/<n>.asj` (and `.seal.json`) with the same files from
    a checked backup, then run *Verify Archive*.
  - There is no selective purge or journal rewrite yet (plan §14, maintenance).
- **Arena `metadata` telemetry is kept only in the raw journal.** It is excluded from the index,
  views and default exports.
- **Attachments:** only whether a file was attached is indexed. Files are not downloaded.
- **Timestamps:** shown as Arena stated them (UTC text). There is no local time-zone conversion.
- **Protocol drift:** new fields are kept and counted as unknown paths. A changed response shape
  may leave conversations list-only until the decoder is updated.
- **Scale:** tested up to 10× the real history (570 conversations, 1,083 records, 77 MB).
  - Replay took 6.6 s, the slowest search 0.43 s, verify 7.4 s and backup 7.2 s; peak memory was
    473 MB.
  - Larger archives should work but have not been measured.
  - Search time grows with the number of matches (up to 200 hits are returned).
- **Platform:** macOS 14 or later, Apple silicon only. The app is not notarized; it is built and
  signed locally for this Mac.
