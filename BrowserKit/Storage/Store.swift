import Foundation

/// Where Browser keeps the little it keeps: one folder of small JSON files,
/// with history.db, the compiled rules and the icons beside them.
public enum Store {
    public static let directory: URL = {
        #if DEBUG
        // Debug builds only: `-browserStore <folder>` keeps a test instance out
        // of the tabs, history and settings of the Browser someone is using.
        if let path = UserDefaults.standard.string(forKey: "browserStore") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Browser", directoryHint: .isDirectory)
    }()

    /// The file or folder called `name`, in a directory that exists.
    public static func url(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name)
    }

    static func read<Value: Decodable>(_ type: Value.Type = Value.self, _ name: String) -> Value? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write(_ value: some Encodable, _ name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(name), options: [.atomic, .completeFileProtection])
    }
}
