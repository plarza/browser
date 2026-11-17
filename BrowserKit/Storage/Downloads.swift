import Foundation
import Observation
import WebKit

/// Downloads: each one opens the save panel at ~/Downloads, and the file
/// keeps the quarantine flag macOS puts on it (LSFileQuarantineEnabled).
/// about://downloads lists them: the file's name, where it went and the
/// site it came from, until Clear.
@MainActor @Observable
public final class Downloads: NSObject, WKDownloadDelegate {
    public static let shared = Downloads()

    @MainActor @Observable
    public final class Item: Identifiable {
        public enum State: String, Codable, Sendable { case active, finished, failed, cancelled }

        public let id = UUID()
        public let name: String
        public let file: URL
        public let site: String
        public internal(set) var state: State
        public internal(set) var received: Int64
        public internal(set) var expected: Int64

        init(name: String, file: URL, site: String, state: State, received: Int64 = 0, expected: Int64 = -1) {
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

    /// Every download until it is cleared, most recent first.
    public private(set) var items: [Item] = []
    /// This session's, for the Mac's sidebar; ones taken off it stay in `items`.
    public private(set) var recent: [Item] = []
    /// Seconds a finished download stays in `recent`.
    public var autoDismiss = 60.0

    /// What a userscript's GM_download hears: progress, then how it ended.
    typealias Report = @MainActor (_ state: Item.State, _ received: Int64, _ expected: Int64) -> Void

    /// A download WebKit has under way, from when a tab hands it over
    /// until it ends.
    private struct Underway {
        /// Held until it ends, so a cancel always reaches it.
        let download: WKDownload
        /// The tab it came from, until that tab's shell has been asked
        /// where to save it.
        var tab: Tab?
        /// The name a userscript wants the save panel to suggest.
        var name: String?
        var report: Report?
        /// Its row, once it has somewhere to go.
        var item: Item?
        var progress: NSKeyValueObservation?
    }

    @ObservationIgnored private var underway: [ObjectIdentifier: Underway] = [:]

    private override init() {
        super.init()
        items = (Store.read([Saved].self, Downloads.file) ?? []).compactMap { saved in
            guard let file = URL(string: saved.file) else { return nil }
            // One that was still coming down when Browser stopped never finished.
            return Item(name: saved.name, file: file, site: saved.site, state: saved.state == .active ? .failed : saved.state,
                        received: saved.size, expected: saved.size)
        }
    }

    // MARK: Starting

    func adopt(_ download: WKDownload, for tab: Tab) -> WKDownloadDelegate {
        underway[ObjectIdentifier(download)] = Underway(download: download, tab: tab)
        return self
    }

    /// A userscript's download: `name` is what the save panel suggests.
    func adopt(_ download: WKDownload, for tab: Tab, name: String?, report: @escaping Report) -> WKDownloadDelegate {
        underway[ObjectIdentifier(download)] = Underway(download: download, tab: tab, name: name, report: report)
        return self
    }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let key = ObjectIdentifier(download)
        guard let asked = underway[key], let tab = asked.tab else {
            end(download, as: .cancelled)
            return nil
        }
        underway[key]?.tab = nil
        let file = await tab.browser?.shell?.tab(tab, saveDownload: Downloads.safeName(asked.name ?? suggestedFilename))
        // It may have ended while the save panel was up: failed, or
        // aborted by its userscript.
        guard underway[key] != nil else { return nil }
        guard let file else {
            end(download, as: .cancelled)
            return nil
        }
        // The save panel already asked about replacing; WebKit won't write over a file.
        try? FileManager.default.removeItem(at: file)
        let item = Item(name: file.lastPathComponent, file: file, site: download.originalRequest?.url?.host ?? tab.url?.host ?? "",
                        state: .active, expected: response.expectedContentLength)
        underway[key]?.item = item
        underway[key]?.progress = download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount, expected = progress.totalUnitCount
            Task { @MainActor in self?.progressed(key, received: received, expected: expected) }
        }
        items.insert(item, at: 0)
        recent.insert(item, at: 0)
        return file
    }

    private func progressed(_ key: ObjectIdentifier, received: Int64, expected: Int64) {
        guard let underway = underway[key], let item = underway.item else { return }
        item.received = received
        if expected > 0 { item.expected = expected }
        underway.report?(.active, item.received, item.expected)
    }

    // MARK: Ending

    public func downloadDidFinish(_ download: WKDownload) {
        end(download, as: .finished)
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        end(download, as: .failed)
    }

    private func end(_ download: WKDownload, as state: Item.State) {
        guard let ended = underway.removeValue(forKey: ObjectIdentifier(download)) else { return }
        guard let item = ended.item else {
            ended.report?(state, 0, -1)
            return
        }
        item.state = state
        if state == .finished, let size = try? item.file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            item.received = Int64(size)
            item.expected = Int64(size)
        }
        // Off the sidebar a minute later; still in about://downloads.
        let wait = autoDismiss
        Task { [weak self, weak item] in
            try? await Task.sleep(for: .seconds(wait))
            if let item { self?.dismiss(item) }
        }
        save()
        ended.report?(state, item.received, item.expected)
    }

    /// Stopped for good: the partial file is deleted and the row leaves the
    /// sidebar. WebKit doesn't report a cancel it was asked for, so it's
    /// ended here.
    public func cancel(_ item: Item) {
        guard item.state == .active, let download = underway.values.first(where: { $0.item === item })?.download else { return }
        download.cancel { _ in }
        end(download, as: .cancelled)
        try? FileManager.default.removeItem(at: item.file)
        dismiss(item)
    }

    /// GM_download's abort(): as cancelling its row, or, with the save
    /// panel still up and no row yet, before there is anything to delete.
    func cancel(_ download: WKDownload) {
        if let item = underway[ObjectIdentifier(download)]?.item {
            cancel(item)
        } else {
            download.cancel { _ in }
            end(download, as: .cancelled)
        }
    }

    // MARK: The lists

    /// Off `recent`; still in `items`.
    public func dismiss(_ item: Item) {
        guard recent.contains(where: { $0 === item }) else { return }
        recent.removeAll { $0 === item }
    }

    public func remove(_ item: Item) {
        guard item.state != .active else { return }
        items.removeAll { $0 === item }
        dismiss(item)
        save()
    }

    /// Everything but what is still coming down. The files stay.
    public func clear() {
        items.removeAll { $0.state != .active }
        recent.removeAll { $0.state != .active }
        save()
    }

    // MARK: On disk

    private static let file = "downloads.json"

    /// A download as downloads.json has it. One still coming down isn't
    /// written until it ends.
    private struct Saved: Codable {
        var name: String
        var file: String
        var site: String
        var state: Item.State
        var size: Int64
    }

    private func save() {
        Store.write(items.filter { $0.state != .active }.map {
            Saved(name: $0.name, file: $0.file.absoluteString, site: $0.site, state: $0.state, size: $0.received)
        }, Downloads.file)
    }

    /// A name a site suggests, made safe to save under: nothing that reads
    /// as a folder, and no dots or spaces at either end (a hidden file, a
    /// lost extension).
    static func safeName(_ suggested: String) -> String {
        let cleaned = suggested.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "download" : cleaned
    }

    #if DEBUG
    /// Rows for snapshots, without downloading anything.
    public func dismissAllForTesting() {
        recent = []
    }

    public func addForTesting(name: String, received: Int64, expected: Int64, state: Item.State) {
        recent.insert(Item(name: name, file: URL(fileURLWithPath: "/tmp/\(name)"), site: "example.com", state: state, received: received, expected: expected), at: 0)
    }
    #endif
}
