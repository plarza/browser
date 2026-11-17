import Foundation

/// Violentmonkey's backup, its exported .zip: each script as a `.user.js`
/// file, and a file called `violentmonkey` that says, for each, whether it
/// is on, whether it updates, where it came from and what it stored.
struct ViolentmonkeyBackup {
    struct Script {
        /// The file's name.
        let file: String
        let source: String
        /// What the backup says about it, if anything.
        fileprivate let entry: [String: Any]?

        var isEnabled: Bool { flag("enabled") }
        /// Violentmonkey's "allow updates".
        var updates: Bool { flag("shouldUpdate") }

        var installURL: URL? {
            ((entry?["custom"] as? [String: Any])?["lastInstallURL"] as? String).flatMap(URL.init(string:))
        }

        /// A switch in the script's `config`, on unless the backup says otherwise.
        private func flag(_ name: String) -> Bool {
            ((entry?["config"] as? [String: Any])?[name] as? NSNumber)?.boolValue ?? true
        }
    }

    /// The scripts, in Violentmonkey's order.
    let scripts: [Script]
    /// Every script's values, by the script's `uri`.
    private let values: [String: Any]

    private static let suffix = ".user.js"

    /// Nil when `data` isn't a zip that can be opened.
    init?(zip data: Data) {
        guard let archive = ZipArchive(data) else { return nil }
        let manifest = archive.files.first { $0.name == "violentmonkey" }
            .flatMap { try? JSONSerialization.jsonObject(with: $0.contents) as? [String: Any] }
        let entries = manifest?["scripts"] as? [String: Any] ?? [:]
        values = manifest?["values"] as? [String: Any] ?? [:]
        let entry = { (file: ZipArchive.File) in entries[String(file.name.dropLast(ViolentmonkeyBackup.suffix.count))] as? [String: Any] }
        let position = { (file: ZipArchive.File) in entry(file)?["position"] as? Int ?? 0 }
        scripts = archive.files
            // Not the `._` files a zip made on a Mac carries beside the real ones.
            .filter { $0.name.hasSuffix(ViolentmonkeyBackup.suffix) && !$0.name.hasPrefix("._") }
            .sorted { position($0) < position($1) }
            .compactMap { file in
                String(data: file.contents, encoding: .utf8).map { Script(file: file.name, source: $0, entry: entry(file)) }
            }
    }

    /// What `script` stored, each value as JSON, or nil if the backup has
    /// none for it. Violentmonkey keys a script's values by its `uri`: its
    /// @namespace and @name, as JavaScript's `escape()` writes them.
    func values(of script: Script, _ meta: UserscriptMeta) -> [String: String]? {
        let uris = [
            (script.entry?["props"] as? [String: Any])?["uri"] as? String,
            "\(ViolentmonkeyBackup.escape(meta.namespace)):\(ViolentmonkeyBackup.escape(meta.name)):",
        ]
        guard let stored = uris.lazy.compactMap({ $0 }).compactMap({ values[$0] as? [String: Any] }).first else { return nil }
        return stored.compactMapValues(ViolentmonkeyBackup.json)
    }

    /// JavaScript's `escape()`.
    static func escape(_ text: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@*_+-./".utf16)
        return text.utf16.map { unit in
            if safe.contains(unit) { return String(UnicodeScalar(UInt8(unit))) }
            return unit < 256 ? String(format: "%%%02X", unit) : String(format: "%%u%04X", unit)
        }.joined()
    }

    /// A stored value as JSON, from either of Violentmonkey's formats: its
    /// newer backups hold JSON, its older ones prefix each value with its
    /// type (`s` string, `n` number, `b` boolean, `o` object).
    static func json(_ stored: Any) -> String? {
        let isJSON = { (text: String) in (try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])) != nil }
        guard let text = stored as? String else {
            return JSONSerialization.isValidJSONObject([stored]) ? UserscriptSource.json(stored) : nil
        }
        if isJSON(text) { return text }
        let rest = String(text.dropFirst())
        switch text.first {
        case "n", "b", "o": return isJSON(rest) ? rest : UserscriptSource.json(text)
        case "s": return UserscriptSource.json(rest)
        default: return UserscriptSource.json(text)
        }
    }
}

extension Userscripts {
    /// Violentmonkey's backup (.zip) or .user.js files. Each script's
    /// @require and @resource files are fetched again.
    public func importFiles(_ files: [URL]) async -> (count: Int, problems: [String]) {
        var count = 0
        var problems: [String] = []
        func add(_ script: ViolentmonkeyBackup.Script, from backup: ViolentmonkeyBackup? = nil) async {
            do {
                try await importScript(script, from: backup)
                count += 1
            } catch {
                problems.append("\(script.file): \(error.localizedDescription)")
            }
        }
        for file in files {
            let name = file.lastPathComponent
            if file.pathExtension.lowercased() == "zip" {
                guard let backup = (try? Data(contentsOf: file)).flatMap(ViolentmonkeyBackup.init(zip:)) else {
                    problems.append("\(name): not a zip that can be opened")
                    continue
                }
                if backup.scripts.isEmpty { problems.append("\(name): no userscripts in it") }
                for script in backup.scripts { await add(script, from: backup) }
            } else if let source = try? String(contentsOf: file, encoding: .utf8) {
                await add(ViolentmonkeyBackup.Script(file: name, source: source, entry: nil))
            } else {
                problems.append("\(name): can't be read")
            }
        }
        return (count, problems)
    }

    /// Installs a script as the backup has it: its switch, whether it
    /// updates, and its values.
    private func importScript(_ imported: ViolentmonkeyBackup.Script, from backup: ViolentmonkeyBackup?) async throws {
        var script = try await install(imported.source, from: imported.installURL)
        script.enabled = imported.isEnabled
        // Violentmonkey's "allow updates" off: kept as it is, like an edited script.
        script.edited = !imported.updates
        put(script)
        if let values = backup?.values(of: imported, script.meta) { setValues(values, of: script.id) }
    }
}
