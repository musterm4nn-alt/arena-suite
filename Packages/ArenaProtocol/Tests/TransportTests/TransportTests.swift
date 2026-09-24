import Foundation
import Testing

@testable import FoundationTransport

private func cookie(_ name: String, _ value: String, domain: String = "arena.ai") -> HTTPCookie {
    HTTPCookie(properties: [
        .name: name, .value: value, .domain: domain, .path: "/", .secure: "TRUE",
        .expires: Date(timeIntervalSince1970: 1_900_000_000),
    ])!
}

@Test func cookiesRoundTripThroughTheCodec() throws {
    let original = [cookie("a", "1"), cookie("b", "2", domain: ".arena.ai")]
    let decoded = try CookieCodec.decode(try CookieCodec.encode(original))
    #expect(decoded.map(\.name) == ["a", "b"])
    #expect(decoded.map(\.value) == ["1", "2"])
    #expect(decoded[1].domain == ".arena.ai")
    #expect(decoded[0].expiresDate == original[0].expiresDate)
}

@Test func importIsolatedPerSessionAndRestrictedToDomains() throws {
    let data = try CookieCodec.encode([cookie("auth", "secret")])
    let first = AccountHTTPSession()
    let second = AccountHTTPSession()
    try first.importCookies(data, domains: ["arena.ai"])
    #expect(try CookieCodec.decode(try first.exportCookies(domains: ["arena.ai"])).map(\.name) == ["auth"])
    #expect(try CookieCodec.decode(try second.exportCookies(domains: ["arena.ai"])).isEmpty)
    #expect(throws: TransportError.cookieJarNotEmpty) { try first.importCookies(data, domains: ["arena.ai"]) }
    let foreign = try CookieCodec.encode([cookie("x", "y", domain: "example.com")])
    #expect(throws: TransportError.foreignCookieDomain) { try second.importCookies(foreign, domains: ["arena.ai"]) }
    #expect(HTTPCookieStorage.shared.cookies?.contains { $0.value == "secret" } != true)
}

@Test func fingerprintChangesWithValueOrExpiryOnly() {
    let base = CookieCodec.fingerprint([cookie("a", "1"), cookie("b", "2")])
    #expect(CookieCodec.fingerprint([cookie("b", "2"), cookie("a", "1")]) == base)
    #expect(CookieCodec.fingerprint([cookie("a", "1"), cookie("b", "3")]) != base)
}

@Test func corruptCookieDataIsRejected() {
    #expect(throws: TransportError.invalidCookieData) { _ = try CookieCodec.decode(Data("not a plist".utf8)) }
    #expect(throws: TransportError.invalidCookieData) { _ = try CookieCodec.decode(Data(count: CookieCodec.maximumBytes + 1)) }
}

/// Cookies parsed from real `Set-Cookie` headers, as the server path produces them, survive the
/// codec with every attribute Arena uses (N-008: Expires, Path, Secure, HttpOnly, SameSite).
@Test func headerParsedCookiesWithEveryAttributeRoundTrip() throws {
    let url = URL(string: "https://arena.ai/api/me")!
    let headers = [
        "Set-Cookie":
            "auth=v1; Domain=arena.ai; Path=/; Expires=Wed, 29 Oct 2027 08:57:46 GMT; Max-Age=34000000; Secure; HttpOnly; SameSite=Lax"
    ]
    let parsed = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
    let original = try #require(parsed.first)
    let data = try CookieCodec.encode(parsed)
    let decoded = try #require(try CookieCodec.decode(data).first)
    #expect(decoded.name == original.name && decoded.value == original.value)
    #expect(decoded.domain == original.domain && decoded.path == original.path)
    #expect(decoded.isSecure && decoded.isHTTPOnly)
    #expect(decoded.expiresDate == original.expiresDate)
    #expect(decoded.sameSitePolicy == original.sameSitePolicy)
    let session = AccountHTTPSession()
    try session.importCookies(data, domains: ["arena.ai"])
    #expect(try CookieCodec.decode(try session.exportCookies(domains: ["arena.ai"])).map(\.value) == ["v1"])
}

@Test func cookieCountLimitIsEnforced() throws {
    let many = (0...CookieCodec.maximumCookies).map { cookie("c\($0)", "v") }
    #expect(throws: TransportError.invalidCookieData) { _ = try CookieCodec.decode(try CookieCodec.encode(many)) }
    let atLimit = Array(many.prefix(CookieCodec.maximumCookies))
    #expect(try CookieCodec.decode(try CookieCodec.encode(atLimit)).count == CookieCodec.maximumCookies)
}
