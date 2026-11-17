import Foundation

/// An installed userscript: its source as written, and what it fetched
/// when it was installed (@require and @resource), so it runs without
/// asking the network for anything.
public struct Userscript: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var source: String
    public var enabled = true
    /// Where it was installed from; updates come from its @updateURL,
    /// @downloadURL, or here.
    public var installURL: String?
    /// Changed here since it was installed: updates leave it alone.
    public var edited = false
    /// @require URL to its text.
    public var requires: [String: String] = [:]
    /// @resource name to what it holds.
    public var resources: [String: Resource] = [:]
    public var installed = Date()
    public var updated = Date()

    public struct Resource: Codable, Equatable, Sendable {
        var url: String
        var mime: String
        /// Base64.
        var data: String
    }

    public var meta: UserscriptMeta { UserscriptMeta.parse(source) ?? UserscriptMeta() }
    public var name: String { meta.name.isEmpty ? "Untitled" : meta.name }

    /// A script that has never been on disk, with an id of its own.
    static func new(_ source: String) -> Userscript {
        Userscript(id: UUID().uuidString.lowercased(), source: source)
    }
}

public struct UserscriptError: LocalizedError {
    public let errorDescription: String?
}

extension UserscriptError {
    init(_ text: String) { errorDescription = text }
}
