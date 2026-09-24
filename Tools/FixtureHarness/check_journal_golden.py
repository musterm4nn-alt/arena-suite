"""Independent reader for Docs/journal-format-v1.md, run against the golden fixture.

Written from the spec, not from the Swift code, so the two implementations check each other.
"""

import hashlib
import json
import pathlib
import re
import struct
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
GOLDEN = ROOT / "Fixtures" / "Journal" / "golden-v1.asj"
DOMAIN = b"ASJ1-record-v1\x00"
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
UUID = re.compile(r"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$")


def fail(message):
    print(f"journal golden check FAILED: {message}")
    sys.exit(1)


def main():
    data = GOLDEN.read_bytes()
    offset, expected_sequence, kinds = 0, 1, []
    while offset < len(data):
        if data[offset : offset + 4] != b"ASJ1":
            fail(f"bad magic at {offset}")
        envelope_length, payload_length = struct.unpack_from("<IQ", data, offset + 4)
        if not 1 <= envelope_length <= 65536 or payload_length > 33554432:
            fail(f"length out of range at {offset}")
        start = offset + 16
        envelope = data[start : start + envelope_length]
        payload = data[start + envelope_length : start + envelope_length + payload_length]
        digest_start = start + envelope_length + payload_length
        digest = data[digest_start : digest_start + 32]
        if len(digest) != 32:
            fail(f"truncated record at {offset}")
        computed = hashlib.sha256(DOMAIN + data[offset + 4 : offset + 16] + envelope + payload).digest()
        if computed != digest:
            fail(f"digest mismatch at {offset}")

        parsed = json.loads(envelope.decode("utf-8"))
        canonical = json.dumps(parsed, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        if canonical.encode("utf-8") != envelope:
            fail(f"envelope at {offset} is not sorted/compact canonical JSON")
        if parsed["format"] != 1:
            fail("format is not 1")
        if parsed["sequence"] != str(expected_sequence):
            fail(f"sequence {parsed['sequence']!r} where {expected_sequence} expected")
        if not UUID.match(parsed["record_id"]):
            fail("record_id is not an uppercase UUID")
        if not ISO.match(parsed["observed_at"]):
            fail("observed_at is not ISO 8601 with milliseconds")
        if "monotonic_ticks" in parsed and not parsed["monotonic_ticks"].isdigit():
            fail("monotonic_ticks is not a decimal string")
        for key, value in parsed.items():
            if value is None:
                fail(f"optional key {key} written as null instead of omitted")
        if not isinstance(parsed["transformations"], list) or not isinstance(parsed["metadata"], dict):
            fail("transformations/metadata have the wrong type")

        kinds.append(parsed["kind"])
        expected_sequence += 1
        offset = digest_start + 32

    if kinds != ["job.started", "exchange", "job.finished"]:
        fail(f"unexpected record kinds {kinds}")
    print(f"Journal golden fixture matches the v1 spec ({len(kinds)} records, {len(data)} bytes)")


if __name__ == "__main__":
    main()
