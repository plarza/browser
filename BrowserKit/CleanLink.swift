import Foundation

/// Removes tracking parameters from addresses before they load. Only names
/// that exist to track are taken out; everything else in the query, its
/// order and the fragment stay. Signed addresses (cloud storage links)
/// are left as they are, since changing them breaks them.
public enum CleanLink {
    static let prefixes = ["utm_", "pk_", "mtm_"]
    static let names: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "li_fat_id", "mc_eid", "mc_cid", "igshid", "igsh", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id",
        "vero_id", "rb_clickid", "s_cid", "ef_id", "srsltid",
    ]
    /// Tracking on these sites only; elsewhere the same name may matter.
    static let perSite: [String: [String]] = [
        "si": ["youtube.com", "youtu.be", "spotify.com"],
        "feature": ["youtube.com", "youtu.be"],
    ]
    static let signed: Set<String> = ["x-amz-signature", "x-goog-signature", "signature", "sig"]

    public static func clean(_ url: URL) -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = parts.percentEncodedQuery, !query.isEmpty
        else { return url }
        let host = parts.host?.lowercased() ?? ""
        let pairs = query.components(separatedBy: "&")
        let keys = pairs.map { pair in
            let key = pair.components(separatedBy: "=")[0]
            return (key.removingPercentEncoding ?? key).lowercased()
        }
        guard !keys.contains(where: signed.contains) else { return url }
        let kept = zip(pairs, keys).filter { !isTracking($0.1, host: host) }.map(\.0)
        guard kept.count != pairs.count else { return url }
        parts.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return parts.url ?? url
    }

    static func isTracking(_ key: String, host: String) -> Bool {
        if names.contains(key) || prefixes.contains(where: key.hasPrefix) { return true }
        return perSite[key]?.contains { host == $0 || host.hasSuffix("." + $0) } ?? false
    }
}
