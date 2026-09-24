"""Independent journal audit (spec reader): per account, detail fetches per entry, jobs, sensitive headers."""
import collections, hashlib, json, pathlib, struct, sys
root = pathlib.Path.home() / "Library/Application Support/Arena Suite/Archive/accounts"
DOMAIN = b"ASJ1-record-v1\x00"
for account in sorted(root.iterdir()):
    seg_dir = account / "journal" / "segments"
    if not seg_dir.is_dir(): continue
    records = []
    for seg in sorted(seg_dir.glob("*.asj")):
        data, off = seg.read_bytes(), 0
        while off < len(data):
            assert data[off:off+4] == b"ASJ1", "magic"
            el, pl = struct.unpack_from("<IQ", data, off + 4)
            env = data[off+16:off+16+el]; payload = data[off+16+el:off+16+el+pl]
            dig = data[off+16+el+pl:off+16+el+pl+32]
            assert hashlib.sha256(DOMAIN + data[off+4:off+16] + env + payload).digest() == dig, "digest"
            records.append((json.loads(env), payload)); off += 16 + el + pl + 32
    seqs = [int(e["sequence"]) for e, _ in records]
    assert seqs == list(range(1, len(seqs) + 1)), "sequence gap"
    details = collections.Counter(e["metadata"]["entry_id"] for e, _ in records if e["kind"] == "exchange" and e["metadata"].get("role") == "detail")
    lists = sum(1 for e, _ in records if e["kind"] == "exchange" and e["metadata"].get("role") == "list")
    jobs = [(e["kind"], e.get("job_id", "")[:8], e["metadata"].get("outcome"), (e["metadata"].get("resumed_by") or "")[:8]) for e, _ in records if e["kind"].startswith("job.")]
    cookies = [h for e, _ in records if e["kind"] == "exchange" for k, h in e["metadata"].get("response_headers", {}).items() if k.lower() == "set-cookie"]
    statuses = collections.Counter(e["metadata"].get("status") for e, _ in records if e["kind"] == "exchange")
    print(account.name[:8], f"records={len(records)} lists={lists} details={sum(details.values())} unique={len(details)} max_per_entry={max(details.values(), default=0)} statuses={dict(statuses)}")
    print("   jobs:", jobs)
    print("   set-cookie values stored:", sorted(set(cookies)) or "none", "| transformations:", sorted({t for e, _ in records if e["kind"] == "exchange" for t in e["transformations"]}))
