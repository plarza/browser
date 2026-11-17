import CryptoKit
import Foundation

/// The icons kept on disk, in `Favicons/` beside history.db: one file per
/// host, holding the icon's bytes as the site served them.
enum FaviconFiles {
    static var folder: URL { Store.directory.appending(path: "Favicons", directoryHint: .isDirectory) }

    /// Named by a hash of the host, so a listing of the folder isn't a list of sites.
    static func file(for host: String) -> URL {
        let name = SHA256.hash(data: Data(("browser.icon." + host).utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: name, directoryHint: .notDirectory)
    }

    static func read(_ host: String) -> Data? {
        try? Data(contentsOf: file(for: host))
    }

    static func keep(_ data: Data, for host: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(for: host), options: [.atomic, .completeFileProtection])
    }

    static func remove(_ host: String) {
        try? FileManager.default.removeItem(at: file(for: host))
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: folder)
    }
}
