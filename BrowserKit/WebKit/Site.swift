import Foundation

/// A site: a registrable domain (`example.co.uk` for `a.b.example.co.uk`),
/// from the public suffix list the system's networking keeps.
public enum Site {
    private typealias IsTopLevel = @convention(c) (CFString) -> Bool

    private static let isPublicSuffix: IsTopLevel? = {
        guard let cfnetwork = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_NOW),
              let symbol = dlsym(cfnetwork, "_CFHostIsDomainTopLevel")
        else { return nil }
        return unsafeBitCast(symbol, to: IsTopLevel.self)
    }()

    /// The public suffix a host ends in (`co.uk`), or nil for an address.
    static func suffix(of host: String) -> String? {
        let host = host.lowercased()
        guard !host.isEmpty, !host.contains(":"), Double(host.replacingOccurrences(of: ".", with: "")) == nil else { return nil }
        let labels = host.split(separator: ".")
        guard let isPublicSuffix else { return labels.last.map(String.init) }
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            if isPublicSuffix(candidate as CFString) { return candidate }
        }
        return labels.last.map(String.init)
    }

    /// The registrable domain; an address or a bare suffix is its own site.
    public static func of(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        guard let suffix = suffix(of: host), host.count > suffix.count else { return host }
        let name = host.dropLast(suffix.count + 1).split(separator: ".").last
        return (name.map { $0 + "." } ?? "") + suffix
    }

    public static func same(_ a: URL?, _ b: URL?) -> Bool {
        guard let a = of(a?.host), let b = of(b?.host) else { return false }
        return a == b
    }

    /// This device itself: plain HTTP to it never leaves the machine, so it
    /// isn't upgraded (as Chrome's and Firefox's HTTPS-only modes don't).
    public static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")
    }
}

extension URL {
    /// An http or https address: a page on the web.
    var isWeb: Bool { scheme == "https" || scheme == "http" }
}
