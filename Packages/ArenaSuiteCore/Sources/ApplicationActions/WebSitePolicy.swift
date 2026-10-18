import Foundation

/// Where the embedded site window may go (ADR 0006). Pure and site-agnostic: the adapter supplies
/// the home page and site domains, the app window asks for a decision per navigation.
public struct WebSitePolicy: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Load in the window.
        case load
        /// Leaves the site: show the address and let the user choose to open it in the default
        /// browser or mail client. Never automatic, because WebKit cannot tell a real click from a
        /// scripted one.
        case askToOpen
        /// Drop silently.
        case ignore
    }

    public let home: URL
    /// Registrable domains of the site. A host matches when it equals one or is a subdomain of it.
    public let siteDomains: Set<String>

    public init(home: URL, siteDomains: Set<String>) {
        self.home = home
        self.siteDomains = Set(siteDomains.map { $0.lowercased() })
    }

    /// An `https` page on the site.
    public func isSitePage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", var host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        return siteDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// A navigation of the window's main frame (a click, a redirect, a script or a form).
    public func mainFrame(_ url: URL) -> Decision {
        if url.scheme?.lowercased() == "about", ["blank", "srcdoc"].contains(url.absoluteString.dropFirst(6).lowercased()) {
            return .load
        }
        if isSitePage(url) { return .load }
        return external(url)
    }

    /// A request for a new window (`target=_blank`, `window.open`). The window never opens a second
    /// web view: site pages load in place, everything else is offered or dropped.
    public func newWindow(_ url: URL?) -> Decision {
        guard let url else { return .ignore }
        if isSitePage(url) { return .load }
        return external(url)
    }

    private func external(_ url: URL) -> Decision {
        switch url.scheme?.lowercased() {
        case "http", "https": url.host(percentEncoded: false)?.isEmpty == false ? .askToOpen : .ignore
        case "mailto": .askToOpen
        default: .ignore
        }
    }
}
