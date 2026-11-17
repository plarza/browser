import Foundation
import Observation

// STUB: the public surface the shells and the rest of BrowserKit rely on.
// The bodies are to be rebuilt; the signatures here are the contract.
@MainActor @Observable
public final class History {
    public static let shared = History()

    public struct Visit: Equatable, Sendable {
        public var url: String
        public var title: String
        /// How many times it was visited.
        public var count = 1
    }

    /// How a page was reached, which sets how much the visit counts.
    public enum Kind: Sendable {
        /// Typed or picked in the address field. Not a search.
        case typed
        /// A link, a page's own navigation, back or forward.
        case link
        /// A reload, or a tab reopened at launch.
        case reload
    }

    /// What the address field shows for what's been typed.
    public struct Completion: Sendable {
        /// The whole site name or address to fill in, if any.
        public var fill: String?
        /// Pages for the list under the field, best first.
        public var pages: [Visit]
    }

    /// Bumped whenever History changes, so a view showing it can keep up.
    public private(set) var version = 0

    func add(_ url: URL, as kind: Kind) {}
    func redirected(from url: URL) {}
    func setTitle(_ title: String, for url: URL) {}
    func title(for url: URL) -> String? { nil }
    func knows(host: String) -> Bool { false }

    /// A page was picked from the list under the address field after `input` was typed.
    public func picked(_ url: String, after input: String) {}
    public func remove(_ url: String) {}
    public func clear() {}
    /// For the address field, looked up off the main thread.
    public func complete(_ typed: String, limit: Int = 8) async -> Completion { Completion(fill: nil, pages: []) }
    /// For about://history: every word, across addresses and titles.
    public func search(_ query: String, limit: Int = 500) async -> [Visit] { [] }
    /// An address without its scheme and `www.`, as the field shows and matches it.
    public nonisolated static func bare(_ url: String) -> String { url }
}
