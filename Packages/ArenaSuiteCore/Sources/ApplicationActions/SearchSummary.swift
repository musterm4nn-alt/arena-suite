import Foundation

/// The lines above search results: how many matches are shown, how many the history filters hid,
/// and whether the search stopped at its limit. A count always says what it counted.
public enum SearchSummary {
    /// `read` hits were read (at most `limit`), `visible` of them pass the filters, and the list
    /// shows at most `shown`.
    public static func lines(read: Int, visible: Int, limit: Int, shown: Int) -> [String] {
        var lines: [String] = []
        if visible > shown {
            lines.append("First \(shown.formatted()) of \(visible.formatted()) matches")
        } else if visible > 0 {
            lines.append(visible == 1 ? "1 match" : "\(visible.formatted()) matches")
        }
        let hidden = read - visible
        if hidden > 0 {
            let noun = visible > 0 ? "more" : (hidden == 1 ? "match" : "matches")
            lines.append("\(hidden.formatted()) \(noun) hidden by the history filters")
        }
        if read >= limit {
            lines.append("The search stopped at \(limit.formatted()) hits; these counts cover only those.")
        }
        return lines
    }
}
