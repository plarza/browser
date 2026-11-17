import Observation
import WebKit

// STUB: the public surface the shells and the rest of BrowserKit rely on.
// The bodies are to be rebuilt; the signatures here are the contract.
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
        public var fraction: Double? { nil }
    }

    /// Every download until it is cleared, most recent first.
    public private(set) var items: [Item] = []
    /// This session's, for the Mac's sidebar; ones taken off it stay in `items`.
    public private(set) var recent: [Item] = []
    /// Seconds a finished download stays in `recent`.
    public var autoDismiss = 60.0

    func adopt(_ download: WKDownload, for tab: Tab) -> WKDownloadDelegate { self }

    /// What a userscript's GM_download hears: progress, then how it ended.
    typealias Report = @MainActor (_ state: Item.State, _ received: Int64, _ expected: Int64) -> Void
    /// A userscript's download: `name` is what the save panel suggests.
    func adopt(_ download: WKDownload, for tab: Tab, name: String?, report: @escaping Report) -> WKDownloadDelegate { self }
    /// GM_download's abort().
    func cancel(_ download: WKDownload) {}

    /// Stopped for good: the partial file is deleted.
    public func cancel(_ item: Item) {}
    /// Off `recent`; still in `items`.
    public func dismiss(_ item: Item) {}
    public func remove(_ item: Item) {}
    public func clear() {}

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? { nil }
}
