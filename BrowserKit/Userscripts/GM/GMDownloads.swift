import WebKit

/// GM_download, through Browser's own downloads: the save panel, the
/// sidebar and about://downloads, like any other.
@MainActor
final class GMDownloads {
    /// The downloads under way, each by the id its script gave it.
    private var downloads: [String: WKDownload] = [:]

    /// Starts the download in the script's own web view, so it has the
    /// tab's cookies and can read the page's blobs. The script hears
    /// `onprogress` as it goes, then `onload`, `onerror` or `onabort`.
    func start(_ call: UserscriptCall) async throws(UserscriptRefusal) {
        guard call.grants.contains("download"), let webView = call.webView, let tab = Tab.showing(webView),
              let id = call.string("did"), let url = call.url("url", schemes: ["https", "http", "blob", "data"])
        else { throw .notGranted }
        var request = URLRequest(url: url)
        for (name, value) in call.arguments["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        let download = await webView.startDownload(using: request)
        downloads[id] = download
        let instance = call.instance
        download.delegate = Downloads.shared.adopt(download, for: tab, name: call.string("name")) { [weak self] state, received, expected in
            let event = switch state {
            case .active: "progress"
            case .finished: "load"
            case .failed: "error"
            case .cancelled: "abort"
            }
            if state != .active { self?.downloads[id] = nil }
            Task { await instance.push(["type": "download", "did": id, "event": event, "loaded": received, "total": expected]) }
        }
    }

    /// `abort()` on what GM_download returned.
    func abort(_ call: UserscriptCall) {
        guard let id = call.string("did"), let download = downloads.removeValue(forKey: id) else { return }
        Downloads.shared.cancel(download)
    }
}
