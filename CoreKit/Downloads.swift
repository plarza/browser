import Foundation
import WebKit

/// Downloads: each one opens the save panel at ~/Downloads, and the file
/// keeps the quarantine flag macOS puts on it (LSFileQuarantineEnabled).
/// about://downloads lists them: the file's name, where it went and the
/// site it came from, until Clear.
@MainActor
public final class Downloads: NSObject, WKDownloadDelegate {
    public static let shared = Downloads()
    public static let changed = Notification.Name("CoreDownloadsChanged")

    public final class Item: Identifiable {
        public enum State: String, Codable { case active, finished, failed }

        public let id: UUID
        public let name: String
        public let file: URL
        public let site: String
        public internal(set) var state: State
        public internal(set) var received: Int64
        public internal(set) var expected: Int64
        weak var download: WKDownload?

        init(id: UUID = UUID(), name: String, file: URL, site: String, state: State, received: Int64 = 0, expected: Int64 = -1) {
            self.id = id
            self.name = name
            self.file = file
            self.site = site
            self.state = state
            self.received = received
            self.expected = expected
        }

        /// 0 to 1, or nil while the size is unknown.
        public var fraction: Double? {
            if state == .finished { return 1 }
            return expected > 0 ? min(1, Double(received) / Double(expected)) : nil
        }
    }

    /// Most recent first.
    public private(set) var items: [Item] = []
    /// This session's, for the sidebar; the ones taken off it stay in `items`.
    public private(set) var recent: [Item] = []

    private var owners: [ObjectIdentifier: Tab] = [:]
    private var watching: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var pending: [ObjectIdentifier: Item] = [:]

    private override init() {
        super.init()
        items = (Store.read([Saved].self, "downloads.json") ?? []).compactMap { saved in
            guard let file = URL(string: saved.file) else { return nil }
            return Item(name: saved.name, file: file, site: saved.site, state: saved.state == .active ? .failed : saved.state,
                        received: saved.size, expected: saved.size)
        }
    }

    func adopt(_ download: WKDownload, for tab: Tab) -> WKDownloadDelegate {
        owners[ObjectIdentifier(download)] = tab
        return self
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let key = ObjectIdentifier(download)
        let tab = owners[key]
        owners[key] = nil
        let name = Downloads.safeName(suggestedFilename)
        guard let tab, let delegate = tab.delegate, let file = await delegate.tab(tab, saveDownload: name) else { return nil }
        // The save panel already asked about replacing; WebKit won't write over a file.
        try? FileManager.default.removeItem(at: file)
        let item = Item(name: file.lastPathComponent, file: file, site: download.originalRequest?.url?.host ?? tab.url?.host ?? "",
                        state: .active, expected: response.expectedContentLength)
        item.download = download
        pending[key] = item
        items.insert(item, at: 0)
        recent.insert(item, at: 0)
        watching[key] = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let done = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor in
                item.received = done
                if total > 0 { item.expected = total }
                self?.changed(save: false)
            }
        }
        changed()
        return file
    }

    public func downloadDidFinish(_ download: WKDownload) {
        finish(download, as: .finished)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, as: .failed)
    }

    private func finish(_ download: WKDownload, as state: Item.State) {
        let key = ObjectIdentifier(download)
        owners[key] = nil
        watching[key] = nil
        guard let item = pending.removeValue(forKey: key) else { return }
        item.state = state
        if state == .finished, let size = try? item.file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            item.received = Int64(size)
            item.expected = Int64(size)
        }
        changed()
    }

    public func cancel(_ item: Item) {
        item.download?.cancel { _ in }
    }

    /// Off the sidebar; still in about://downloads.
    public func dismiss(_ item: Item) {
        recent.removeAll { $0 === item }
        changed(save: false)
    }

    public func remove(_ item: Item) {
        guard item.state != .active else { return }
        items.removeAll { $0 === item }
        recent.removeAll { $0 === item }
        changed()
    }

    public func clear() {
        items.removeAll { $0.state != .active }
        recent.removeAll { $0.state != .active }
        changed()
    }

    private func changed(save: Bool = true) {
        if save {
            Store.write(items.filter { $0.state != .active }.map {
                Saved(name: $0.name, file: $0.file.absoluteString, site: $0.site, state: $0.state, size: $0.received)
            }, "downloads.json")
        }
        NotificationCenter.default.post(name: Downloads.changed, object: nil)
    }

    private struct Saved: Codable {
        var name: String
        var file: String
        var site: String
        var state: Item.State
        var size: Int64
    }

    static func safeName(_ suggested: String) -> String {
        let cleaned = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "download" : cleaned
    }

    #if DEBUG
    /// Rows for snapshots, without downloading anything.
    public func dismissAllForTesting() {
        recent = []
        changed(save: false)
    }

    public func addForTesting(name: String, received: Int64, expected: Int64, state: Item.State) {
        let item = Item(name: name, file: URL(fileURLWithPath: "/tmp/\(name)"), site: "example.com", state: state, received: received, expected: expected)
        recent.insert(item, at: 0)
        changed(save: false)
    }
    #endif
}
