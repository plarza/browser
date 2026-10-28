import Foundation

// Copyright (c) 2026 Office Commun. MIT License (see LICENSES/MIT-Office-Commun.txt).

/// An address without the parameters that only say where a click came from.
/// Unknown parameters stay, so do order, encoding and the fragment; a signed
/// address is left alone since taking anything out would break it.
public enum CleanLink {
    /// Names that track and do nothing else, on any site. `utm_` covers
    /// every one of Google Analytics' campaign tags.
    static let tracking: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "msclkid", "yclid",
        "twclid", "ttclid", "mc_eid", "igshid", "igsh", "_hsenc", "_hsmi", "mkt_tok",
    ]

    /// Names that track on some sites and may mean something on others: a
    /// YouTube or Spotify share's `si` is who shared it.
    static let trackingOn: [String: Set<String>] = [
        "si": ["youtube.com", "youtu.be", "spotify.com"],
    ]

    /// A signed address: S3, Google Cloud, CloudFront and the like.
    static let signatures: Set<String> = [
        "x-amz-signature", "x-goog-signature", "signature", "sig",
    ]

    /// The address without its tracking parameters, or the same address
    /// when there is nothing to take out or it can't be touched safely.
    public static func clean(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = parts.percentEncodedQuery, !query.isEmpty
        else { return url }
        let host = (parts.host ?? "").lowercased()
        let pieces = query.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
        let names = pieces.map { piece -> String in
            let raw = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return (raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw).lowercased()
        }
        if names.contains(where: signatures.contains) { return url }
        let kept = zip(pieces, names).filter { !tracks($0.1, on: host) }.map(\.0)
        guard kept.count < pieces.count else { return url }
        parts.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return parts.url ?? url
    }

    static func tracks(_ name: String, on host: String) -> Bool {
        if name.hasPrefix("utm_") || tracking.contains(name) { return true }
        guard let sites = trackingOn[name] else { return false }
        return sites.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
