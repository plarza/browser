import Foundation

/// A site: a registrable domain (`example.co.uk` for `a.b.example.co.uk`),
/// from the public suffix list the system's networking keeps.
enum Site {
    private typealias TopLevel = @convention(c) (CFString) -> Bool

    private static let isPublicSuffix: TopLevel? = {
        guard let cfnetwork = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_NOW),
              let symbol = dlsym(cfnetwork, "_CFHostIsDomainTopLevel")
        else { return nil }
        return unsafeBitCast(symbol, to: TopLevel.self)
    }()

    /// The public suffix a host ends in (`co.uk`), or nil for an address.
    static func suffix(of host: String) -> String? {
        let host = host.lowercased()
        guard !host.isEmpty, !host.contains(":"), Double(host.replacingOccurrences(of: ".", with: "")) == nil else { return nil }
        let labels = host.split(separator: ".")
        guard let isPublicSuffix else { return labels.last.map(String.init) }
        for i in labels.indices {
            let candidate = labels[i...].joined(separator: ".")
            if isPublicSuffix(candidate as CFString) { return candidate }
        }
        return labels.last.map(String.init)
    }

    /// The registrable domain; an address or a bare suffix is its own site.
    static func of(_ host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        guard let suffix = suffix(of: host), host.count > suffix.count else { return host }
        let rest = host.dropLast(suffix.count + 1)
        return (rest.split(separator: ".").last.map { $0 + "." } ?? "") + suffix
    }

    static func same(_ a: URL?, _ b: URL?) -> Bool {
        guard let a = of(a?.host), let b = of(b?.host) else { return false }
        return a == b
    }
}
