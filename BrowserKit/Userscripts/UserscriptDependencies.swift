import Foundation

/// Browser's own requests for a script: its @require and @resource files,
/// its updates, a notification's picture.
enum UserscriptFetch {
    /// A file fetched whole, and the type the server says it is. Anything
    /// but a 2xx answer throws.
    static func file(at url: URL, in session: URLSession) async throws -> (data: Data, mime: String) {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        return (data, response.mimeType ?? "application/octet-stream")
    }
}

/// The @require and @resource files a script names, fetched when it is
/// installed so it never fetches them as it runs.
struct UserscriptDependencies {
    /// @require URL to its text.
    var requires: [String: String] = [:]
    /// @resource name to what it holds.
    var resources: [String: Userscript.Resource] = [:]

    /// Fetches what `meta` names, relative to where the script came from.
    /// `installed`: the script as it is now, whose files are kept rather
    /// than fetched again. Throws when a file can't be fetched, or a
    /// @require isn't JavaScript.
    @MainActor
    static func fetch(for meta: UserscriptMeta, relativeTo base: URL?, keeping installed: Userscript? = nil) async throws -> UserscriptDependencies {
        var fetched = UserscriptDependencies()
        let session = Engine.session(timeout: 30)
        defer { session.finishTasksAndInvalidate() }
        for name in meta.require where fetched.requires[name] == nil {
            if let text = installed?.requires[name] {
                fetched.requires[name] = text
                continue
            }
            guard let url = URL(string: name, relativeTo: base)?.absoluteURL,
                  let (data, _) = try? await UserscriptFetch.file(at: url, in: session)
            else { throw UserscriptError("Couldn't fetch @require \(name)") }
            let text = String(decoding: data, as: UTF8.self)
            if let error = UserscriptSyntax.error(in: text) { throw UserscriptError("@require \(name): \(error)") }
            fetched.requires[name] = text
        }
        for resource in meta.resources {
            if let kept = installed?.resources[resource.name], kept.url == resource.url {
                fetched.resources[resource.name] = kept
                continue
            }
            guard let url = URL(string: resource.url, relativeTo: base)?.absoluteURL,
                  let (data, mime) = try? await UserscriptFetch.file(at: url, in: session)
            else { throw UserscriptError("Couldn't fetch @resource \(resource.name)") }
            fetched.resources[resource.name] = Userscript.Resource(url: resource.url, mime: mime, data: data.base64EncodedString())
        }
        return fetched
    }
}
