"""Independent audit of archive journals (reads Docs/journal-format-v1.md, not the Swift code).

Usage: python3 Tools/FixtureHarness/audit_archive_journals.py [ARCHIVE_ROOT]
Default root: ~/Library/Application Support/Arena Suite/Archive. Exits 1 on any violation.
Checks: record digests and magic, continuous sequences, at most one detail snapshot per conversation
version (no refetch of committed work), Set-Cookie values never stored, credential omission declared,
job.started/job.finished pairing (every closed job, interrupted jobs resumed_by a real job), and that no
conversation ID appears in two accounts.
"""
import collections, hashlib, json, pathlib, struct, sys

DOMAIN = b"ASJ1-record-v1\x00"
root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path.home() / "Library/Application Support/Arena Suite/Archive"
failures = []
owners = collections.defaultdict(set)

def fail(account, message):
    failures.append(f"{account[:8]}: {message}")

for account in sorted((root / "accounts").iterdir()) if (root / "accounts").is_dir() else []:
    seg_dir = account / "journal" / "segments"
    if not seg_dir.is_dir():
        continue
    name = account.name
    records = []
    for seg in sorted(seg_dir.glob("*.asj")):
        data, off = seg.read_bytes(), 0
        while off < len(data):
            if data[off:off + 4] != b"ASJ1":
                fail(name, f"bad magic in {seg.name} at {off}"); break
            el, pl = struct.unpack_from("<IQ", data, off + 4)
            env, payload = data[off + 16:off + 16 + el], data[off + 16 + el:off + 16 + el + pl]
            digest = data[off + 16 + el + pl:off + 16 + el + pl + 32]
            if hashlib.sha256(DOMAIN + data[off + 4:off + 16] + env + payload).digest() != digest:
                fail(name, f"digest mismatch in {seg.name} at {off}"); break
            records.append(json.loads(env)); off += 16 + el + pl + 32
    seqs = [int(e["sequence"]) for e in records]
    if seqs != list(range(1, len(seqs) + 1)):
        fail(name, "sequence gap or reorder")
    versions = collections.Counter()
    started, finished, resumed_by = set(), set(), {}
    for e in records:
        meta = e.get("metadata", {})
        if e["kind"] == "exchange":
            if "credential_omitted" not in e.get("transformations", []):
                fail(name, f"exchange {e['sequence']} lacks credential_omitted")
            for header, value in meta.get("response_headers", {}).items():
                if header.lower() == "set-cookie" and value != "[omitted]":
                    fail(name, f"Set-Cookie value stored in record {e['sequence']}")
            if meta.get("role") == "detail" and meta.get("status") == 200:
                versions[(meta.get("entry_id"), meta.get("source_updated_at"))] += 1
                owners[meta.get("entry_id")].add(name)
        elif e["kind"] == "job.started":
            started.add(e.get("job_id"))
        elif e["kind"] == "job.finished":
            finished.add(e.get("job_id"))
            if meta.get("resumed_by"):
                resumed_by[e.get("job_id")] = meta["resumed_by"]
    for (entry, version), count in versions.items():
        # Unstamped conversations are refetched by design; every stamped version at most once.
        if version is not None and count > 1:
            fail(name, f"conversation version fetched {count} times")
    if finished - started:
        fail(name, "job.finished without job.started")
    for job, successor in resumed_by.items():
        if successor not in started:
            fail(name, "interrupted job resumed_by an unknown job")
    print(f"{name[:8]} records={len(records)} jobs={len(started)} snapshots={sum(versions.values())} "
          f"conversations={len({k for k, _ in versions})} open_jobs={len(started - finished)}")

for entry, accounts in owners.items():
    if len(accounts) > 1:
        failures.append(f"a conversation appears in {len(accounts)} accounts")

if failures:
    print("AUDIT FAILED:\n  " + "\n  ".join(failures)); sys.exit(1)
print("Archive journal audit passed")
