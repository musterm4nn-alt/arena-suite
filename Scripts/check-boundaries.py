"""Small fail-closed import inventory for the currently implemented production modules."""

import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[1]
allowed = {
    "App": {"AppKit", "SwiftUI", "ApplicationActions", "SuiteDomain", "Observation", "Foundation", "ArchiveIndex", "CoreText"},
    "Packages/ArenaSuiteCore/Sources/SuiteDomain": {"Foundation"},
    "Packages/ArenaSuiteCore/Sources/ApplicationActions": {"Foundation", "SuiteDomain", "CaptureJournal", "ArchiveIndex", "CryptoKit"},
    "Packages/ArenaSuiteCore/Sources/CaptureJournal": {"Foundation", "Darwin", "CryptoKit"},
    "Packages/ArenaSuiteCore/Sources/ArchiveIndex": {"Foundation", "SuiteDomain", "GRDB", "CryptoKit"},
    "Packages/ArenaProtocol/Sources/ArenaAdapter": {
        "Foundation", "SuiteDomain", "ApplicationActions", "FoundationTransport", "Security", "CaptureJournal",
    },
    "Packages/ArenaProtocol/Sources/FoundationTransport": {"Foundation", "Darwin"},
    # Read-only MCP (plan v3 §14): archive access only, never the adapter or transport.
    "Packages/ArenaSuiteMCP/Sources/ArchiveMCP": {"Foundation", "SuiteDomain", "ApplicationActions", "ArchiveIndex"},
    "Packages/ArenaSuiteMCP/Sources/arena-suite-mcp": {"Foundation", "ArchiveMCP"},
}
# Read-only MCP (plan v3 §14): no network and no writes (journal, index, registry, exports, files).
# The only write allowed is the JSON-RPC response to stdout (`output.write(`, a FileHandle).
mcp_forbidden = re.compile(
    r"URLSession|URLRequest|NWConnection|NWListener|Socket|JournalWriter|\.writer\(|"
    r"\.project\(|\.rebuild\(|\.reset\(|\.apply\(|\.replay\(|checkAgainstJournal|"
    r"ArchiveIndex\(url:|DatabasePool|DatabaseQueue|\.save\(|\.load\(\)|PrivateFile\.|"
    r"\.export\(|BackupService|VerificationService|DiagnosticsService|HistorySyncService|AccountService|"
    r"FileManager\.default\.(?:create|remove|move|copy|replace|setAttributes|trash)|"
    r"\.write\(to:|(?<![.\w])open\(|\bchmod\(|\bunlink\(|\brename\(",
)
# The deny-list must keep catching these (self-test on every run).
for probe in [
    "x.apply(a)", "try registry.save([])", "try registry.load()", "ArchiveService.replay(journals: j)",
    "try PrivateFile.write(d, to: u)", "try d.write(to: u)", "FileManager.default.createDirectory(at: u)",
    "ExportService(archive: a).export(account: x)", "let f = open(p, O_RDWR)", "a.checkAgainstJournal(scratch: u)",
    "index.reset()", "try await journals.writer(for: a)", "URLSession.shared", "ArchiveIndex(url: u)", "chmod(p, 0)",
]:
    assert mcp_forbidden.search(probe), f"MCP deny-list self-test missed: {probe}"
for allowed_text in ["ArchiveTools.readOnly(archiveRoot: root)", "output.write(response)", "JournalStore(archiveRoot: r)"]:
    assert not mcp_forbidden.search(allowed_text), f"MCP deny-list self-test over-matched: {allowed_text}"

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
    permitted = set(allowed[owners[0]])
    # The composition root alone may wire concrete adapter implementations.
    if relative == "App/AppComposition.swift":
        permitted.add("ArenaAdapter")
    assert imports <= permitted, (
        f"Forbidden imports in {relative}: {imports - permitted}"
    )
    if owners[0] != "Packages/ArenaProtocol/Sources/ArenaAdapter":
        assert not re.search(
            r"arena\.ai|lmarena\.ai|/api/history|/ai-proxy/", path.read_text()
        ), relative
    if owners[0].startswith("Packages/ArenaSuiteMCP/"):
        forbidden = mcp_forbidden.findall(path.read_text())
        assert not forbidden, f"Write or network API in read-only MCP: {relative}: {sorted(set(forbidden))}"
print(f"Production import boundary check passed ({len(files)} files)")
