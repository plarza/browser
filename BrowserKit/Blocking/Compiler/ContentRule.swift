import Foundation

/// One rule of a WebKit content rule list, spelt as WebKit's JSON spells
/// it. A value, so two filters that come to the same rule compare equal,
/// and so compiled rules can cross from the compiler's thread to the main
/// actor.
struct ContentRule: Hashable, Sendable, Encodable {
    var trigger: Trigger
    var action: Action

    struct Trigger: Hashable, Sendable, Encodable {
        /// A regex without alternation or counted repeats: all WebKit takes.
        var urlFilter: String
        var resourceType: [ResourceType]?
        var loadType: [LoadType]?
        /// The site showing, `*` in front for its subdomains too.
        var ifDomain: [String]?
        var unlessDomain: [String]?
        /// Patterns for the address of the page showing.
        var ifTopURL: [String]?

        private enum CodingKeys: String, CodingKey {
            case urlFilter = "url-filter"
            case resourceType = "resource-type"
            case loadType = "load-type"
            case ifDomain = "if-domain"
            case unlessDomain = "unless-domain"
            case ifTopURL = "if-top-url"
        }

        /// Any scheme, then any subdomains: what `||` starts a filter with.
        static let anyHost = "^[^:]+://+([^:/]+\\.)?"

        /// Matches every address.
        static let everything = ".*"

        /// A url-filter for addresses on `host` and its subdomains.
        static func urlFilter(onHost host: String) -> String {
            anyHost + escape(host) + "[/:]"
        }

        /// A host as it stands in a url-filter.
        static func escape(_ host: String) -> String {
            host.replacingOccurrences(of: ".", with: "\\.")
        }
    }

    struct Action: Hashable, Sendable, Encodable {
        var type: Kind
        /// What `hide` hides.
        var selector: String?

        enum Kind: String, Hashable, Sendable, Encodable {
            case block
            case hide = "css-display-none"
            /// An exception: undoes the rules before it in its list.
            case ignorePreviousRules = "ignore-previous-rules"
        }
    }

    enum ResourceType: String, Hashable, Sendable, Encodable {
        case image, script, font, media, fetch, websocket, ping, other, document, popup
        case styleSheet = "style-sheet"
    }

    enum LoadType: String, Hashable, Sendable, Encodable {
        case firstParty = "first-party"
        case thirdParty = "third-party"
    }
}

extension ContentRule {
    static func block(_ trigger: Trigger) -> ContentRule {
        ContentRule(trigger: trigger, action: Action(type: .block))
    }

    static func exception(_ trigger: Trigger) -> ContentRule {
        ContentRule(trigger: trigger, action: Action(type: .ignorePreviousRules))
    }

    /// Hides whatever any of `selectors` matches.
    static func hide(_ selectors: some Sequence<String>, where trigger: Trigger) -> ContentRule {
        ContentRule(trigger: trigger, action: Action(type: .hide, selector: selectors.joined(separator: ", ")))
    }

    var isException: Bool { action.type == .ignorePreviousRules }

    /// A content rule list as the JSON WebKit compiles.
    static func encode(_ rules: [ContentRule]) throws -> String {
        String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
    }
}
