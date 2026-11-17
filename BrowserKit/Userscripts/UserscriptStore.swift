import Foundation

/// The scripts on disk, in `Userscripts`: each as `<id>.json` (its source,
/// its switch, and the @require and @resource files it fetched), with the
/// values it stored beside it in `<id>.values.json`.
enum UserscriptStore {
    private static let folder: URL = {
        let folder = Store.url("Userscripts")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private static func file(_ id: String) -> URL { folder.appending(path: "\(id).json") }
    private static func valuesFile(_ id: String) -> URL { folder.appending(path: "\(id).values.json") }

    /// Every script, in the order they were installed.
    static func scripts() -> [Userscript] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".values.json") }
            .compactMap { file in
                (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Userscript.self, from: $0) }
            }
            .sorted { $0.installed < $1.installed }
    }

    static func write(_ script: Userscript) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(script) else { return }
        try? data.write(to: file(script.id), options: [.atomic, .completeFileProtection])
    }

    /// A script's stored values, each as JSON; nil if it has stored none.
    static func values(of id: String) -> [String: String]? {
        (try? Data(contentsOf: valuesFile(id))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    }

    static func write(_ values: [String: String], of id: String) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        try? data.write(to: valuesFile(id), options: [.atomic, .completeFileProtection])
    }

    /// The script and its values, off the disk.
    static func remove(_ id: String) {
        for file in [file(id), valuesFile(id)] { try? FileManager.default.removeItem(at: file) }
    }
}
