import Foundation

/// Updates: once a day, with the filter lists, each script not edited in
/// Browser checks its @updateURL, @downloadURL or where it came from, and
/// installs itself again when its @version went up.
extension Userscripts {
    /// When the scripts were last checked.
    private static let checked = "userscripts-checked.json"

    /// Checks now if a day has passed, and looks again every hour.
    func checkForUpdatesDaily() {
        Task {
            while !Task.isCancelled {
                let last = Store.read(Date.self, Userscripts.checked) ?? .distantPast
                if Date().timeIntervalSince(last) > 24 * 60 * 60, scripts.contains(where: { !$0.edited }) {
                    await checkForUpdates()
                }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    public func checkForUpdates() async {
        Store.write(Date(), Userscripts.checked)
        let session = Engine.session(timeout: 30)
        defer { session.finishTasksAndInvalidate() }
        for script in scripts where !script.edited {
            let meta = script.meta
            let installURL = script.installURL ?? ""
            guard let check = Userscripts.addresses([meta.updateURL, meta.downloadURL, installURL]).first,
                  let (data, _) = try? await UserscriptFetch.file(at: check, in: session)
            else { continue }
            var source = String(decoding: data, as: UTF8.self)
            guard let latest = UserscriptMeta.parse(source), UserscriptMeta.newer(latest.version, than: meta.version) else { continue }
            if check.path.hasSuffix(".meta.js") {
                // Only the metadata block was there: the script itself is elsewhere.
                guard let full = Userscripts.addresses([latest.downloadURL, meta.downloadURL, installURL]).first(where: { !$0.path.hasSuffix(".meta.js") }),
                      let (code, _) = try? await UserscriptFetch.file(at: full, in: session)
                else { continue }
                source = String(decoding: code, as: UTF8.self)
            }
            _ = try? await install(source, from: script.installURL.flatMap(URL.init(string:)) ?? check)
        }
    }

    /// Those of `candidates` that are addresses on the web, in order.
    private static func addresses(_ candidates: [String]) -> [URL] {
        candidates.compactMap { URL(string: $0) }.filter { ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
    }
}
