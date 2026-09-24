"""Small fail-closed import inventory for the currently implemented production modules."""

import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[1]
allowed = {
    "App": {"AppKit", "SwiftUI", "ApplicationActions"},
    "Packages/ArenaSuiteCore/Sources/SuiteDomain": {"Foundation"},
    "Packages/ArenaSuiteCore/Sources/ApplicationActions": {"Foundation", "SuiteDomain"},
    "Packages/ArenaSuiteCore/Sources/CaptureJournal": {"Foundation", "Darwin", "CryptoKit"},
    "Packages/ArenaProtocol/Sources/ArenaAdapter": {"Foundation", "SuiteDomain"},
}
files = list((root / "App").rglob("*.swift"))
for package in (root / "Packages").iterdir():
    files.extend((package / "Sources").rglob("*.swift"))
for path in files:
    relative = path.relative_to(root).as_posix()
    owners = [
        directory for directory in allowed if relative.startswith(directory + "/")
    ]
    assert len(owners) == 1, f"Unregistered production module: {relative}"
    imports = set(
        re.findall(
            r"\bimport\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(\w+)",
            path.read_text(),
        )
    )
    assert imports <= allowed[owners[0]], (
        f"Forbidden imports in {relative}: {imports - allowed[owners[0]]}"
    )
    if owners[0] != "Packages/ArenaProtocol/Sources/ArenaAdapter":
        assert not re.search(
            r"arena\.ai|lmarena\.ai|/api/history|/ai-proxy/", path.read_text()
        ), relative
print(f"Production import boundary check passed ({len(files)} files)")
