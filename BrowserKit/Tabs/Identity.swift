import CryptoKit
import Foundation
import WebKit

/// One identity: everything a site could use to recognise this tab again.
/// A website data store (cookies, every kind of storage, HTTP cache, HSTS,
/// TLS sessions and the connection pool, all in its own network session).
///
/// A fresh identity is ephemeral: nothing it holds ever touches the disk,
/// and dropping the last reference to it is the wipe.
@MainActor
public final class Identity {
    public enum Kind: Equatable, Sendable {
        /// Lives until the next navigation, or until a Persist tab closes.
        case fresh
        /// A whitelisted domain's one jar on disk, shared by every tab.
        case whitelisted(String)
        /// A Persist tab's own jar on disk, kept across relaunches until the
        /// tab closes or Persist is turned off.
        case kept(UUID)
    }

    public let kind: Kind
    public let store: WKWebsiteDataStore

    private init(kind: Kind, store: WKWebsiteDataStore) {
        self.kind = kind
        self.store = store
    }

    public static func fresh() -> Identity {
        Identity(kind: .fresh, store: .nonPersistent())
    }

    private static var jars: [String: Identity] = [:]

    /// The same object for every tab on that domain, so they share one
    /// network session as well as one jar.
    public static func whitelisted(_ domain: String) -> Identity {
        if let jar = jars[domain] { return jar }
        let jar = Identity(kind: .whitelisted(domain), store: WKWebsiteDataStore(forIdentifier: Whitelist.storeID(for: domain)))
        jars[domain] = jar
        return jar
    }

    public static func kept(_ id: UUID = UUID()) -> Identity {
        Identity(kind: .kept(id), store: WKWebsiteDataStore(forIdentifier: id))
    }

    /// The jar on disk, for a Persist tab's identity.
    var keptID: UUID? {
        if case .kept(let id) = kind { return id }
        return nil
    }

    /// Deleted once the web views using it have let go, which can take a
    /// moment after they close.
    static func forget(kept id: UUID) async {
        for _ in 0 ..< 60 {
            do { return try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {}
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// A domain taken off the whitelist leaves nothing behind.
    static func forget(whitelisted domain: String) async {
        jars[domain] = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: Whitelist.storeID(for: domain))
    }

    /// Jars on disk that nothing refers to any more (a Persist tab that was
    /// open when Browser stopped without saving, say) are deleted.
    static func removeOrphans(keeping kept: Set<UUID>) async {
        var keep = kept.union(Preferences.shared.settings.whitelist.map(Whitelist.storeID(for:)))
        keep.formUnion(Extensions.storeIDs)
        for id in await WKWebsiteDataStore.allDataStoreIdentifiers where !keep.contains(id) {
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
    }
}

extension UUID {
    /// The same UUID for the same text every time: a version 5 style UUID
    /// from its SHA-256.
    init(hashing text: String) {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        self = bytes.withUnsafeBytes { $0.load(as: UUID.self) }
    }
}
