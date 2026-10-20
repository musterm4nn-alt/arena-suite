"""Small fail-closed import inventory for the currently implemented production modules."""

import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
allowed = {
    "App": {"AppKit", "SwiftUI", "ApplicationActions", "SuiteDomain", "Observation", "Foundation", "ArchiveIndex", "CoreText"},
    "Packages/ArenaSuiteCore/Sources/SuiteDomain": {"Foundation"},
    # AppleArchive and System: Apple system frameworks for encrypted backups (AEA), not dependencies.
    "Packages/ArenaSuiteCore/Sources/ApplicationActions": {
        "Foundation", "SuiteDomain", "CaptureJournal", "ArchiveIndex", "CryptoKit", "AppleArchive", "System",
    },
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
    r"\.export\(|\.build\(recipe:|BackupService|VerificationService|DiagnosticsService|HistorySyncService|AccountService|"
    r"FileManager\.default\.(?:create|remove|move|copy|replace|setAttributes|trash)|"
    r"\.write\(to:|(?<![.\w])open\(|\bchmod\(|\bunlink\(|\brename\(|"
    # Local vote notes (Docs/vote-notes-2026-10-20.md) are the app's alone: MCP neither reads nor writes them.
    r"[Vv]oteNote|vote_notes|LocalControl|local\.control|appendLocal|"
    # Refresh and sync go to Arena (Docs/sync-refresh-2026-10-20.md): never from MCP.
    r"ConversationRefresh|RefreshError|HistorySyncing|ArenaHistorySync|conversation_refresh",
)
# The deny-list must keep catching these (self-test on every run).
for probe in [
    "x.apply(a)", "try registry.save([])", "try registry.load()", "ArchiveService.replay(journals: j)",
    "try PrivateFile.write(d, to: u)", "try d.write(to: u)", "FileManager.default.createDirectory(at: u)",
    "ExportService(archive: a).export(account: x)", "let f = open(p, O_RDWR)", "a.checkAgainstJournal(scratch: u)",
    "index.reset()", "try await journals.writer(for: a)", "URLSession.shared", "ArchiveIndex(url: u)", "chmod(p, 0)",
    "try await datasets.build(recipe: r, in: u, appVersion: v)",
    "try archive.voteNotes(account: a, conversationID: c)", "VoteNoteService(sync: s, archive: a)",
    "SELECT * FROM vote_notes", "LocalControl.draft(n, account: a)", "kind == \"local.control\"",
    "try await sync.appendLocal(d, account: a)",
    "ConversationRefreshService(sync: s, archive: a)", "catch RefreshError.notRefreshable",
    "ArenaHistorySync(sessions: s)", "let e: any HistorySyncing", "job_kind == \"conversation_refresh\"",
]:
    assert mcp_forbidden.search(probe), f"MCP deny-list self-test missed: {probe}"
for allowed_text in ["ArchiveTools.readOnly(archiveRoot: root)", "output.write(response)", "JournalStore(archiveRoot: r)"]:
    assert not mcp_forbidden.search(allowed_text), f"MCP deny-list self-test over-matched: {allowed_text}"

# Embedded site pane (ADR 0006): WebKit only in this file, and there no scripts, no page, cookie
# or storage reads, no scheme handlers, no user-agent change, no content capture (of the page or
# the screen), no dynamic dispatch that could reach any of these, no default, shared or ephemeral
# data store, and exactly one web view (no aliases or other constructors).
web_window = "App/ArenaWebPane.swift"
web_forbidden = re.compile(
    r"evaluateJavaScript|callAsyncJavaScript|WKUserScript|addUserScript|userContentController|WKScriptMessageHandler|"
    r"WKContentWorld|httpCookieStore|WKHTTPCookieStore|HTTPCookie|fetchDataRecords|setURLSchemeHandler|WKURLSchemeHandler|"
    r"customUserAgent|applicationNameForUserAgent|isInspectable|createWebArchiveData|takeSnapshot|createPDF|printOperation|"
    r"loadHTMLString|loadFileURL|loadSimulatedRequest|\.load\(\s*\w+\s*,\s*mimeType|WKWebsiteDataStore\.default\(|"
    r"WKWebsiteDataStore\(\s*\)|\.nonPersistent\(|isHidden|alphaValue|javaScriptCanOpenWindowsAutomatically|"
    r"bitmapImageRepForCachingDisplay|cacheDisplay|dataWithPDF|dataWithEPS|CGWindowListCreateImage|NSBitmapImageRep|"
    r"ScreenCaptureKit|SCScreenshotManager|NSImage\(|"
    r"NSClassFromString|NSSelectorFromString|\.perform\(|#selector|value\(forKey|setValue\(|objc_msgSend|dlsym|"
    r"class_getInstanceMethod|method_exchangeImplementations|typealias|WKWebView\.init|WKWebView\.self|\.init\(frame",
)
for probe in [
    "webView.evaluateJavaScript(\"document.cookie\")", "try await webView.callAsyncJavaScript(s, contentWorld: .page)",
    "configuration.userContentController.add(self, name: \"x\")", "store.httpCookieStore.getAllCookies()",
    "webView.customUserAgent = \"Safari\"", "configuration.applicationNameForUserAgent = \"Version/18 Safari\"",
    "webView.isInspectable = true", "webView.takeSnapshot(with: nil)", "webView.loadHTMLString(h, baseURL: u)",
    "configuration.websiteDataStore = WKWebsiteDataStore.default()", "webView.isHidden = true",
    "store.fetchDataRecords(ofTypes: t)", "configuration.setURLSchemeHandler(h, forURLScheme: \"x\")",
    "webView.createWebArchiveData { _ in }", "configuration.preferences.setValue(true, forKey: \"x\")",
    # Evasions raised in review (2026-10-18).
    "configuration.websiteDataStore = WKWebsiteDataStore()", "webView.bitmapImageRepForCachingDisplay(in: r)",
    "webView.cacheDisplay(in: r, to: rep)", "webView.dataWithPDF(inside: r)", "CGWindowListCreateImage(r, o, w, i)",
    "NSClassFromString(\"WKUserScript\")", "webView.perform(NSSelectorFromString(\"evaluateJavaScript:completionHandler:\"))",
    "typealias V = WKWebView", "let v = WKWebView.init(frame: r, configuration: c)", "let t = WKWebView.self",
    "webView.value(forKey: \"x\")", "NSImage(data: d)",
]:
    assert web_forbidden.search(probe), f"Web window deny-list self-test missed: {probe}"
for allowed_text in [
    "WKWebsiteDataStore(forIdentifier: account.rawValue)", "webView.load(URLRequest(url: home))",
    "store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)",
    "WKWebsiteDataStore.remove(forIdentifier: id)", "if action.shouldPerformDownload { }",
    "let webView = WKWebView(frame: .zero, configuration: configuration)",
]:
    assert not web_forbidden.search(allowed_text), f"Web window deny-list self-test over-matched: {allowed_text}"

# Every tracked Swift file is product code (registered below), a test, a package manifest, or an
# out-of-product tool. A new top-level source folder fails here until it is registered.
tracked = subprocess.run(["git", "-C", str(root), "ls-files", "*.swift"], capture_output=True, text=True, check=True).stdout.splitlines()
for relative in tracked:
    in_product = relative.startswith("App/") or re.match(r"Packages/[^/]+/Sources/", relative)
    exempt = re.match(r"Packages/[^/]+/(Tests/|Package\.swift$)", relative) or relative.startswith("Tools/")
    assert in_product or exempt, f"Swift file outside every registered location: {relative}"
    if relative != web_window and not relative.startswith("Tools/") and (root / relative).exists():
        assert not re.search(r"\bimport\s+WebKit\b", (root / relative).read_text()), f"WebKit outside {web_window}: {relative}"

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
    if relative == web_window:
        permitted.add("WebKit")
        text = path.read_text()
        forbidden = web_forbidden.findall(text)
        assert not forbidden, f"Forbidden web API in {relative}: {sorted(set(forbidden))}"
        assert len(re.findall(r"\bWKWebView\(", text)) == 1, f"{relative} must create exactly one WKWebView"
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
