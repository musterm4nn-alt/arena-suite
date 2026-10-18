import ApplicationActions
import Foundation

/// The site shown in the embedded window (ADR 0006): Arena's observed origin and cookie domain
/// (B-001, N-002). Assumption: the site stays on this domain. If Arena moves pages elsewhere, those
/// pages open in the default browser instead of the window, which fails visibly and safely.
public enum ArenaWebsite {
    public static let policy = WebSitePolicy(home: ArenaRoutes.origin, siteDomains: ArenaRoutes.cookieDomains)
}
