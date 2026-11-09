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

@Test func onlyASitePagesAddressGivesSegments() {
    #expect(policy.pageSegments(url("https://example.org/c/abc-123?x=1#f")) == ["abc-123", "c"])
    #expect(policy.pageSegments(url("https://www.example.org/code/c/9/")) == ["9", "c", "code"])
    #expect(policy.pageSegments(url("https://example.org/")) == [])
    #expect(policy.pageSegments(url("https://evil.com/c/abc-123")) == [])
    #expect(policy.pageSegments(url("http://example.org/c/abc-123")) == [])
    #expect(policy.pageSegments(nil) == [])
}

@Test func downloadsMayComeFromThePageItself() {
    for text in ["https://example.org/f.zip", "http://cdn.example.net/f", "blob:https://example.org/6f1c", "data:application/zip;base64,UEs="] {
        #expect(policy.isDownloadable(url(text)), "\(text)")
    }
    for text in ["file:///etc/passwd", "javascript:alert(1)", "about:blank", "mailto:a@example.org"] {
        #expect(!policy.isDownloadable(url(text)), "\(text)")
    }
}

@Test func onlyTheSitesOwnBlobsLoad() {
    #expect(policy.mainFrame(url("blob:https://example.org/6f1c")) == .load)
    #expect(policy.newWindow(url("blob:https://www.example.org/6f1c")) == .load)
    #expect(policy.mainFrame(url("blob:https://evil.com/6f1c")) == .ignore)
    #expect(policy.mainFrame(url("blob:http://example.org/6f1c")) == .ignore)
    #expect(policy.newWindow(url("blob:null/6f1c")) == .ignore)
}
