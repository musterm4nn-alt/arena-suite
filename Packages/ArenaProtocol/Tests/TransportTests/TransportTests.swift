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
