import AppKit
import ApplicationActions
import SuiteDomain
import SwiftUI
import WebKit

// The embedded site window (ADR 0006): a visible web view the user drives. This is the only file
// that may import WebKit. It never injects or evaluates scripts, reads the page, cookies or web
// storage, registers scheme handlers, changes the user agent, or creates a second web view
// (`Scripts/check-boundaries.py` enforces this). Nothing from here is journaled; conversations reach
// the archive only through the account's user-initiated history sync.

/// One persistent web profile per archiver account, separate from Safari, the other accounts and the
/// native Keychain session. Profiles are deleted only for accounts the user removed
/// (`WebProfileLifecycle`); the pending list lives in this app's defaults, which have the same
/// per-app scope as WebKit's profiles (not per archive root).
@MainActor
final class ArenaWebProfiles {
    let policy: WebSitePolicy
    let lifecycle: WebProfileLifecycle
    private static let pendingKey = "webProfilesPendingRemoval"

    init(policy: WebSitePolicy) {
        self.policy = policy
        let saved = (UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? [])
            .compactMap(UUID.init(uuidString:)).map(AccountID.init(rawValue:))
        lifecycle = WebProfileLifecycle(
            pending: saved,
            persist: { UserDefaults.standard.set($0.map(\.rawValue.uuidString), forKey: Self.pendingKey) },
            remover: { account in
                do {
                    try await WKWebsiteDataStore.remove(forIdentifier: account.rawValue)
                    return true
                } catch {
                    // Still held by a web view being torn down; retried on close or at the next launch.
                    return false
                }
            })
    }

    /// The site's host, for window and button labels; the adapter owns the value.
    var siteName: String { policy.home.host(percentEncoded: false) ?? policy.home.absoluteString }

    func dataStore(for account: AccountID) -> WKWebsiteDataStore { WKWebsiteDataStore(forIdentifier: account.rawValue) }
}

/// Toolbar and banner state for one window, mirrored from the web view.
@MainActor @Observable
final class ArenaWebPage {
    fileprivate(set) var canGoBack = false
    fileprivate(set) var canGoForward = false
    fileprivate(set) var isLoading = false
    fileprivate(set) var host: String?
    /// A page (not a click) asked to leave the site; the user decides.
    var offered: URL?
    var problem: String?
    var notice: String?
    @ObservationIgnored fileprivate weak var webView: WKWebView?
    @ObservationIgnored fileprivate var home: URL?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reloadOrStop() {
        guard let webView else { return }
        if webView.isLoading { webView.stopLoading() } else { problem = nil; webView.reload() }
    }
    func goHome() {
        guard let webView, let home else { return }
        problem = nil
        webView.load(URLRequest(url: home))
    }
    /// The current page's address, for "Open in Browser".
    var currentURL: URL? { webView?.url }

    /// Deletes everything this profile stored (sign-in included), then shows the home page.
    func clearWebData() async {
        guard let webView else { return }
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        notice = "Web data for this profile was cleared. You are signed out in this window."
        goHome()
    }
}

struct ArenaWebWindow: View {
    static let id = "arena-web"
    let accountID: AccountID?
    @Bindable var accounts: AccountsModel
    let profiles: ArenaWebProfiles
    @State private var page = ArenaWebPage()
    @State private var confirmingClear = false

    private var account: AccountSummary? { accounts.accounts.first { $0.id == accountID } }

    var body: some View {
        Group {
            if let accountID, let account {
                ArenaWebView(account: accountID, profiles: profiles, page: page)
                    .safeAreaInset(edge: .top, spacing: 0) { banners }
                    .toolbar { toolbar(account) }
                    // A label for the profile, not a verified identity: the app never reads which
                    // Arena account is signed in there (ADR 0006).
                    .navigationTitle("\(profiles.siteName) · web profile of \(account.displayName)")
                    .navigationSubtitle(page.host ?? "")
                    .confirmationDialog(
                        "Clear web data for \(account.displayName)'s web profile?", isPresented: $confirmingClear
                    ) {
                        Button("Clear Web Data", role: .destructive) { Task { await page.clearWebData() } }
                    } message: {
                        Text("This signs you out in this window and deletes its cookies and site storage. Your archive is not affected.")
                    }
            } else if accounts.loading {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "Account not found", systemImage: "person.crop.circle.badge.xmark",
                    description: Text("This account is not in Arena Suite's account list. Nothing is shown and nothing is deleted."))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .task { await accounts.start() }
    }

    @ToolbarContentBuilder
    private func toolbar(_ account: AccountSummary) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { page.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(!page.canGoBack).keyboardShortcut("[", modifiers: .command)
            Button { page.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .disabled(!page.canGoForward).keyboardShortcut("]", modifiers: .command)
            Button { page.reloadOrStop() } label: {
                Label(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            Button { page.goHome() } label: { Label("Home", systemImage: "house") }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if let progress = accounts.syncing[account.id] {
                Text(AccountsView.describe(progress)).font(Theme.caption).foregroundStyle(.secondary)
                Button("Stop Sync") { Task { await accounts.cancelSync(account.id) } }.font(Theme.text)
            } else {
                Button("Sync History") { Task { await accounts.syncHistory(account.id) } }
                    .font(Theme.text)
                    .disabled(account.state != .signedIn)
                    .help(
                        account.state == .signedIn
                            ? "Archive this account's Arena history, including chats from this window"
                            : "Sign this account in under Manage Accounts to archive it")
            }
            Menu {
                Button("Open Page in Browser") { if let url = page.currentURL { NSWorkspace.shared.open(url) } }
                    .disabled(page.currentURL == nil)
                Divider()
                Button("Clear Web Data…") { confirmingClear = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if let url = page.offered {
                banner("This leads outside \(profiles.siteName): \(url.scheme == "mailto" ? url.absoluteString : url.host(percentEncoded: false) ?? url.absoluteString)") {
                    Button("Open in Browser") { NSWorkspace.shared.open(url); page.offered = nil }
                    Button("Dismiss") { page.offered = nil }
                }
            }
            if let problem = page.problem {
                banner(problem) {
                    Button("Reload") { page.reloadOrStop() }
                    Button("Dismiss") { page.problem = nil }
                }
            }
            if let notice = page.notice {
                banner(notice) { Button("Dismiss") { page.notice = nil } }
            }
        }
        .font(Theme.text)
    }

    private func banner(_ text: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(text).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The web view itself. Created once per window, for one account's profile.
private struct ArenaWebView: NSViewRepresentable {
    let account: AccountID
    let profiles: ArenaWebProfiles
    let page: ArenaWebPage

    func makeCoordinator() -> Coordinator { Coordinator(account: account, profiles: profiles, page: page) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profiles.dataStore(for: account)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(webView)
        webView.load(URLRequest(url: profiles.policy.home))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private let account: AccountID
        private let profiles: ArenaWebProfiles
        private let page: ArenaWebPage
        private var policy: WebSitePolicy { profiles.policy }
        private var observations: [NSKeyValueObservation] = []

        init(account: AccountID, profiles: ArenaWebProfiles, page: ArenaWebPage) {
            self.account = account
            self.profiles = profiles
            self.page = page
        }

        /// The profile counts as in use for exactly the web view's lifetime in this window.
        func attach(_ webView: WKWebView) {
            profiles.lifecycle.opened(account)
            page.webView = webView
            page.home = policy.home
            // Navigation state only (WebKit's own properties); never page content.
            func watch<Value>(_ keyPath: KeyPath<WKWebView, Value>) {
                observations.append(
                    webView.observe(keyPath, options: [.initial, .new]) { [weak self] _, _ in
                        Task { @MainActor in self?.mirror() }
                    })
            }
            watch(\.canGoBack)
            watch(\.canGoForward)
            watch(\.isLoading)
            watch(\.url)
        }

        func detach() {
            observations.forEach { $0.invalidate() }
            observations = []
            page.webView = nil
            let (lifecycle, account) = (profiles.lifecycle, account)
            Task { await lifecycle.closed(account) }
        }

        private func mirror() {
            guard let webView = page.webView else { return }
            page.canGoBack = webView.canGoBack
            page.canGoForward = webView.canGoForward
            page.isLoading = webView.isLoading
            page.host = webView.url?.host(percentEncoded: false)
        }

        private func apply(_ decision: WebSitePolicy.Decision, to url: URL?, in webView: WKWebView) {
            guard let url else { return }
            switch decision {
            case .load: webView.load(URLRequest(url: url))
            case .askToOpen: page.offered = url
            case .ignore: break
            }
        }

        // MARK: Navigation

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // Each request is decided first, and only then acted on.
            guard let target = action.targetFrame else {
                // A new-window request: handled here so that no second web view is ever created.
                decisionHandler(.cancel)
                apply(policy.newWindow(action.request.url), to: action.request.url, in: webView)
                return
            }
            let url = action.request.url
            if action.shouldPerformDownload, ["http", "https"].contains(url?.scheme?.lowercased() ?? "") {
                return decisionHandler(.download)  // in any frame; always through a save panel
            }
            // Subframes (challenge frames, embeds) load as the page asks, as in any browser.
            guard target.isMainFrame, let url else { return decisionHandler(.allow) }
            let decision = policy.mainFrame(url)
            if decision == .load {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                apply(decision, to: url, in: webView)
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(response.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            page.problem = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        private func report(_ error: any Error) {
            let error = error as NSError
            // Cancelled loads and loads this window turned into a download or stopped by policy.
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
            if error.domain == "WebKitErrorDomain", error.code == 102 { return }  // frame load interrupted
            page.problem = "The page could not be loaded: \(error.localizedDescription)"
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // No automatic reload (ADR 0006): the user decides.
            page.problem = "The page stopped unexpectedly. Reload to continue."
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            download.delegate = self
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        // MARK: Windows and panels

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            apply(policy.newWindow(action.request.url), to: action.request.url, in: webView)
            return nil
        }

        func webView(
            _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor () -> Void
        ) {
            let alert = Self.alert(message, frame: frame)
            present(alert, in: webView) { _ in completionHandler() }
        }

        func webView(
            _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor (Bool) -> Void
        ) {
            let alert = Self.alert(message, frame: frame)
            alert.addButton(withTitle: "Cancel")
            present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn) }
        }

        func webView(
            _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
            initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void
        ) {
            let alert = Self.alert(prompt, frame: frame)
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = field
            present(alert, in: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
        }

        func webView(
            _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.message = "Choose what to upload to \(frame.securityOrigin.host)."
            guard let window = webView.window else { return completionHandler(nil) }
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        }

        func webView(
            _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.deny)
        }

        private static func alert(_ message: String, frame: WKFrameInfo) -> NSAlert {
            let alert = NSAlert()
            alert.messageText = "\(frame.securityOrigin.host) says"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            return alert
        }

        private func present(_ alert: NSAlert, in webView: WKWebView, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
            guard let window = webView.window else { return completion(.cancel) }
            alert.beginSheetModal(for: window) { response in completion(response) }
        }

        // MARK: Downloads (always through a save panel)

        /// Downloads that replace an existing file are written beside it first; the original is
        /// replaced only after the download finished, so a failed download never destroys it.
        private var replacements: [ObjectIdentifier: (partial: URL, final: URL)] = [:]

        func download(
            _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
            completionHandler: @escaping @MainActor (URL?) -> Void
        ) {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            guard let window = download.webView?.window else { return completionHandler(nil) }
            panel.beginSheetModal(for: window) { [self] response in
                guard response == .OK, let url = panel.url else { return completionHandler(nil) }
                guard FileManager.default.fileExists(atPath: url.path) else { return completionHandler(url) }
                let partial = url.deletingLastPathComponent()
                    .appendingPathComponent("\(url.lastPathComponent).arenasuite-download-\(UUID().uuidString.prefix(8))")
                replacements[ObjectIdentifier(download)] = (partial, url)
                completionHandler(partial)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let (partial, final) = replacements.removeValue(forKey: ObjectIdentifier(download)) else {
                page.notice = "Download finished."
                return
            }
            do {
                _ = try FileManager.default.replaceItemAt(final, withItemAt: partial)
                page.notice = "Download finished: \(final.lastPathComponent) was replaced."
            } catch {
                page.notice = "The download was saved as \(partial.lastPathComponent) because \(final.lastPathComponent) could not be replaced."
            }
        }

        func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
            if let (partial, _) = replacements.removeValue(forKey: ObjectIdentifier(download)) {
                // Only our own partial file; the original was never touched.
                try? FileManager.default.removeItem(at: partial)
            }
            if (error as NSError).code == NSURLErrorCancelled { return }
            page.notice = "The download failed: \(error.localizedDescription)"
        }
    }
}
