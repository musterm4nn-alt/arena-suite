import AppKit
import ApplicationActions
import SuiteDomain
import SwiftUI
import WebKit

// The embedded site pane (ADR 0006): a visible web view inside the main window that the user
// drives. This is the only file that may import WebKit. It never injects or evaluates scripts, reads
// the page, cookies or web storage, registers scheme handlers, changes the user agent, or creates a
// web view other than the one per user-opened session (`Scripts/check-boundaries.py` enforces the
// code rules). Nothing from here is journaled; conversations reach the archive only through the
// account's user-initiated history sync.

/// One persistent web profile per archiver account, separate from Safari, the other accounts and the
/// native Keychain session, and the sessions the user opened.
///
/// A session starts only from the user's click (Open, a site entry in the sidebar, or a tab) and
/// keeps its page while the archive is shown, like a background browser tab: the app never acts on
/// it, and dialogs, uploads and downloads it asks for then are declined. Nothing opens a session at
/// launch; Close Session or removing the account ends it. Profiles are deleted only for accounts the user removed (`WebProfileLifecycle`);
/// the pending list lives in this app's defaults, which have the same per-app scope as WebKit's
/// profiles (not per archive root).
@MainActor @Observable
final class ArenaWebProfiles {
    let policy: WebSitePolicy
    @ObservationIgnored let lifecycle: WebProfileLifecycle
    private(set) var sessions: [AccountID: ArenaWebSession] = [:]
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
                    // Still held by a web view being torn down; retried at the next launch.
                    return false
                }
            })
    }

    /// The site's host, for titles and button labels; the adapter owns the value.
    var siteName: String { policy.home.host(percentEncoded: false) ?? policy.home.absoluteString }

    /// Opens the account's session (the user clicked Open, a site entry or a tab), or returns the
    /// one already open.
    @discardableResult
    func open(_ account: AccountID) -> ArenaWebSession {
        if let session = sessions[account] { return session }
        let session = ArenaWebSession(
            policy: policy, store: WKWebsiteDataStore(forIdentifier: account.rawValue))
        sessions[account] = session
        lifecycle.opened(account)
        return session
    }

    /// Ends the session: its page stops and its web view is released. The profile (sign-in) stays.
    func close(_ account: AccountID) async {
        guard let session = sessions.removeValue(forKey: account) else { return }
        session.end()
        await lifecycle.closed(account)
    }

    /// The user removed the account: its session ends and its profile is deleted (or retried at the
    /// next launch if WebKit still holds it).
    func accountRemoved(_ account: AccountID) async {
        await lifecycle.accountRemoved(account)  // deferred while the session is open…
        await close(account)  // …and attempted as it closes
    }
}

/// One account's open page: the web view, its delegate and the toolbar state. Owned by
/// `ArenaWebProfiles`; shown by whichever pane is displaying the account, never by two at once.
@MainActor
final class ArenaWebSession {
    let page: ArenaWebPage
    fileprivate let webView: WKWebView
    /// Strong: WebKit holds its delegates weakly.
    private let coordinator: Coordinator

    fileprivate init(policy: WebSitePolicy, store: WKWebsiteDataStore) {
        let page = ArenaWebPage()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let coordinator = Coordinator(policy: policy, page: page)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = true
        coordinator.attach(webView)
        self.page = page
        self.webView = webView
        self.coordinator = coordinator
        webView.load(URLRequest(url: policy.home))
    }

    /// Puts the web view into `host`, moving it from wherever it was shown before.
    fileprivate func show(in host: NSView) {
        guard webView.superview !== host else { return }
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
    }

    fileprivate func end() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        coordinator.detach()
        webView.removeFromSuperview()
    }
}

/// Toolbar and banner state for one session, mirrored from the web view.
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
        notice = "Web data for this profile was cleared. You are signed out of this web profile."
        goHome()
    }
}

/// The site in the main window's detail column, for one account.
struct ArenaWebPane: View {
    let accountID: AccountID
    @Bindable var accounts: AccountsModel
    let profiles: ArenaWebProfiles
    /// The user's click on Open or a tab: the main window opens the session, and collapses its
    /// sidebar when coming from outside the site.
    let open: (AccountID) -> Void
    @State private var confirmingClear = false

    private var account: AccountSummary? { accounts.accounts.first { $0.id == accountID } }

    var body: some View {
        VStack(spacing: 0) {
            if let account, let session = profiles.sessions[accountID] {
                header(account, page: session.page)
                ArenaWebHost(session: session)
                    .safeAreaInset(edge: .top, spacing: 0) { banners(session.page) }
                    .confirmationDialog(
                        "Clear web data for \(account.displayName)'s web profile?", isPresented: $confirmingClear
                    ) {
                        Button("Clear Web Data", role: .destructive) { Task { await session.page.clearWebData() } }
                    } message: {
                        Text("This signs you out of this web profile and deletes its cookies and site storage. Your archive is not affected.")
                    }
            } else if let account {
                #if DEBUG
                // Development: `--preview-site-header` draws the open page's header over the closed
                // placeholder, with a page model that has no web view (nothing is loaded).
                if CommandLine.arguments.contains("--preview-site-header") {
                    header(account, page: ArenaWebPage())
                } else {
                    HeaderBar(divider: true) { profileTabs } trailing: { EmptyView() }
                }
                #else
                HeaderBar(divider: true) { profileTabs } trailing: { EmptyView() }
                #endif
                VStack(spacing: 10) {
                    Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("\(profiles.siteName) is closed").font(Theme.heading)
                    Text("Nothing is loaded until you open it.").foregroundStyle(.secondary)
                    Button("Open \(profiles.siteName)") { open(accountID) }.buttonStyle(.arenaPill).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.xmark").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Account not found").font(Theme.heading)
                    Text("This account is not in Arena Suite's account list. Nothing is shown and nothing is deleted.")
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // A label for the profile, not a verified identity: the app never reads which Arena
        // account is signed in there (ADR 0006).
        .navigationTitle(account.map(title) ?? profiles.siteName)
        .frame(minWidth: 720, maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func title(_ account: AccountSummary) -> String { "\(profiles.siteName) · web profile of \(account.displayName)" }

    /// One tab per account in the app, each its own web profile. A click shows that account's
    /// session, opening it if needed: the user's click, as from the sidebar's site entry. The app
    /// never reads which Arena account a profile is signed in to (ADR 0006), so every account in
    /// the app gets a tab, and a dot marks sessions open in the background. When the tabs don't
    /// fit, they scroll, so the header's own controls keep their room.
    private var profileTabs: some View {
        ViewThatFits(in: .horizontal) {
            tabRow
            // The pane is rebuilt for each account, so the shown tab is scrolled into view.
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) { tabRow }
                    .onAppear { proxy.scrollTo(accountID, anchor: .center) }
            }
            .frame(height: 24)
        }
    }

    private var tabRow: some View {
        HStack(spacing: 2) {
            ForEach(accounts.accounts, id: \.id) { other in
                let shown = other.id == accountID
                let running = profiles.sessions[other.id] != nil
                // A click shows another account's page, or opens a closed session (this one's too,
                // like the Open button below it).
                Button {
                    if !shown || !running { open(other.id) }
                } label: {
                    // The dot sits in the tab's padding, so it doesn't change the tab's width.
                    Text(other.displayName).truncationMode(.middle)
                        .overlay(alignment: .leading) {
                            if running && !shown {
                                Circle().fill(Theme.primaryText.opacity(0.5)).frame(width: 5, height: 5)
                                    .offset(x: -7).accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(ArenaTabStyle(selected: shown))
                .help(
                    shown
                        ? (running ? "Shown: \(title(other))" : "Open \(title(other))")
                        : running ? "Show \(title(other)) (open in the background)" : "Open \(title(other))")
                .accessibilityLabel(title(other))
                .accessibilityValue(shown ? (running ? "Shown" : "Shown, closed") : running ? "Open in the background" : "Closed")
                .accessibilityHint(shown && running ? "" : running ? "Shows its page" : "Opens its session")
                .accessibilityAddTraits(shown ? .isSelected : [])
                .id(other.id)
            }
        }
    }

    /// The page's controls, in the window's top band like the archive's header.
    private func header(_ account: AccountSummary, page: ArenaWebPage) -> some View {
        HeaderBar(divider: true) {
            HStack(spacing: 2) {
                Button { page.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!page.canGoBack).keyboardShortcut("[", modifiers: .command)
                    .help("Back (⌘[)")
                Button { page.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!page.canGoForward).keyboardShortcut("]", modifiers: .command)
                    .help("Forward (⌘])")
                Button { page.reloadOrStop() } label: {
                    Label(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help(page.isLoading ? "Stop (⌘R)" : "Reload (⌘R)")
                Button { page.goHome() } label: { Label("Home", systemImage: "house") }
                    .help("\(profiles.siteName) home")
            }
            .buttonStyle(.arenaIcon)
            profileTabs.padding(.leading, 6)
            if let host = page.host, host != profiles.siteName {
                Text(host).foregroundStyle(.tertiary).lineLimit(1)
            }
        } trailing: {
            if let progress = accounts.syncing[account.id] {
                Text(AccountsView.describe(progress)).font(Theme.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("Stop Sync") { Task { await accounts.cancelSync(account.id) } }.buttonStyle(.arenaPill).fixedSize()
            } else {
                Button("Sync History") { Task { await accounts.syncHistory(account.id) } }
                    .buttonStyle(.arenaPill)
                    .fixedSize()
                    .disabled(account.state != .signedIn)
                    .help(
                        account.state == .signedIn
                            ? "Archive this account's Arena history with its own Arena Suite sign-in (the account signed in on this page is not checked)"
                            : "Sign this account in under Manage Accounts to archive it")
            }
            Menu {
                Button("Open Page in Browser") { if let url = page.currentURL { NSWorkspace.shared.open(url) } }
                    .disabled(page.currentURL == nil)
                Divider()
                Button("Close \(profiles.siteName) Session") { Task { await profiles.close(account.id) } }
                Button("Clear Web Data…") { confirmingClear = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.arenaIcon)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func banners(_ page: ArenaWebPage) -> some View {
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
            actions().buttonStyle(.arenaPill)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.raised)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }
}

/// Shows a session's web view. The web view moves between hosts as the pane comes and goes; leaving
/// the pane keeps it running in its session, like a background tab.
private struct ArenaWebHost: NSViewRepresentable {
    let session: ArenaWebSession

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        session.show(in: host)
        return host
    }

    /// Nothing to update; re-showing here could pull the web view back into a host being replaced.
    func updateNSView(_ host: NSView, context: Context) {}

    static func dismantleNSView(_ host: NSView, coordinator: ()) {
        host.subviews.forEach { $0.removeFromSuperview() }
    }
}

extension ArenaWebSession {
    @MainActor
    fileprivate final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        private let policy: WebSitePolicy
        private let page: ArenaWebPage
        private var observations: [NSKeyValueObservation] = []

        init(policy: WebSitePolicy, page: ArenaWebPage) {
            self.policy = policy
            self.page = page
        }

        func attach(_ webView: WKWebView) {
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
        }

        private func mirror() {
            guard let webView = page.webView else { return }
            page.canGoBack = webView.canGoBack
            page.canGoForward = webView.canGoForward
            page.isLoading = webView.isLoading
            page.host = webView.url?.host(percentEncoded: false)
        }

        /// The window the page is shown in, if it is on screen: nil while the archive or another
        /// account is shown (the web view is in no window) or the window is minimized or hidden.
        /// Nothing is presented for a page that is not visible.
        private func visibleWindow(_ webView: WKWebView?, declining what: String) -> NSWindow? {
            if let window = webView?.window, window.isVisible, !window.isMiniaturized { return window }
            page.notice = "\(what) was declined because the page was not shown."
            return nil
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
            guard let window = visibleWindow(webView, declining: "A file upload") else { return completionHandler(nil) }
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
            guard let window = visibleWindow(webView, declining: "A page dialog") else { return completion(.cancel) }
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
            guard let window = visibleWindow(download.webView, declining: "A download") else { return completionHandler(nil) }
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
