import Foundation
import Testing

@testable import ApplicationActions

// ADR 0006: the embedded window's main frame stays on the site; leaving it is always the user's
// choice, offered and never automatic. "example.org" stands in for the site (only the adapter knows
// Arena's domain).

private let policy = WebSitePolicy(home: URL(string: "https://example.org")!, siteDomains: ["Example.org"])
private func url(_ text: String) -> URL { URL(string: text)! }

@Test(arguments: [
    "https://example.org", "https://example.org/", "https://www.example.org/c/123?x=1#frag", "https://EXAMPLE.ORG/path",
    "https://example.org./trailing-dot", "https://www.example.org./both", "https://a.b.example.org/deep",
])
func sitePagesLoad(_ text: String) {
    #expect(policy.isSitePage(url(text)))
    #expect(policy.mainFrame(url(text)) == .load)
    #expect(policy.newWindow(url(text)) == .load)
}

@Test(arguments: [
    "http://example.org/",  // never downgrade the site to plain HTTP inside the window
    "https://evilexample.org/", "https://example.org.evil.com/", "https://example.org@evil.com/",
    "https://www.example.org@evil.com/", "https://evil.com/?next=https://example.org", "https://evil.com/example.org",
    "https://accounts.google.com/o/oauth2",
    "https://xn--xample-2of.org/",  // IDN lookalike (Cyrillic "е"), as URL parsing presents it
])
func otherWebPagesAreOnlyOffered(_ text: String) {
    #expect(!policy.isSitePage(url(text)))
    #expect(policy.mainFrame(url(text)) == .askToOpen)
    #expect(policy.newWindow(url(text)) == .askToOpen)
}

@Test func otherSchemesAreHandledNarrowly() {
    #expect(policy.mainFrame(url("about:blank")) == .load)
    #expect(policy.mainFrame(url("about:srcdoc")) == .load)
    #expect(policy.newWindow(url("about:blank")) == .ignore, "no second web view, even blank")
    #expect(policy.mainFrame(url("mailto:someone@example.org")) == .askToOpen)
    for text in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,hi", "ftp://example.org/", "x-app://open", "about:config"] {
        #expect(policy.mainFrame(url(text)) == .ignore, "\(text)")
        #expect(policy.newWindow(url(text)) == .ignore, "\(text)")
    }
    #expect(policy.newWindow(nil) == .ignore)
    #expect(policy.mainFrame(url("https:///nohost")) == .ignore)
    #expect(policy.mainFrame(url("http:///nohost")) == .ignore)
}

@Test func domainsAreCaseInsensitive() {
    #expect(policy.siteDomains == ["example.org"])
    #expect(policy == WebSitePolicy(home: url("https://example.org"), siteDomains: ["EXAMPLE.org"]))
}
