#if DEBUG
import AppKit
import Network

/// The self-test's own web site, on this Mac: every page, icon, redirect,
/// download and filter list the test loads, so it never waits on the
/// internet. Plain HTTP on loopback (which Browser doesn't upgrade), local
/// connections only, on a port the system picks.
final class TestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "browser.selftest.server")
    private(set) var port: UInt16 = 0

    /// Two sites on one server: two hosts, so two origins and two jars.
    var site: String { "http://localhost:\(port)" }
    var other: String { "http://127.0.0.1:\(port)" }
    func url(_ path: String, on base: String? = nil) -> URL { URL(string: (base ?? site) + path)! }

    /// Enough rules to need two content rule lists (WebKit takes 150,000 each).
    static let ruleCount = 160_000

    init() {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        listener = try! NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [unowned self] in self.serve($0) }
        listener.start(queue: queue)
        ready.wait()
        port = listener.port!.rawValue
    }

    private func serve(_ connection: NWConnection, _ received: Data = Data()) {
        if received.isEmpty { connection.start(queue: queue) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [unowned self] chunk, _, done, error in
            let data = received + (chunk ?? Data())
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { self.serve(connection, data) }
                return
            }
            let target = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: " ").dropFirst().first ?? "/"
            if target == "/download-slow" {
                // A big file that sends its first part and then waits, for
                // cancelling partway: the connection stays open until Browser drops it.
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 100000000\r\n"
                    + "Content-Disposition: attachment; filename=\"browser-slow.bin\"\r\nCache-Control: no-store\r\n\r\n"
                connection.send(content: Data(head.utf8) + Data(count: 1 << 16), completion: .contentProcessed { _ in })
                return
            }
            let (status, type, body) = Self.respond(to: URLComponents(string: String(target)) ?? URLComponents())
            var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n"
            if target.hasPrefix("/download") { head += "Content-Disposition: attachment; filename=\"browser-test.txt\"\r\n" }
            connection.send(content: Data((head + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func respond(to request: URLComponents) -> (String, String, Data) {
        let path = request.path
        let html = { (title: String, body: String) in
            ("200 OK", "text/html; charset=utf-8", Data("<!doctype html><title>\(title)</title><link rel=icon href=/icon.png>\(body)".utf8))
        }
        switch path {
        case _ where path.hasPrefix("/page/"):
            let name = path.dropFirst(6).replacingOccurrences(of: "-", with: " ")
            return html(name, "<h1>\(name)</h1><p>" + String(repeating: "WebKit is a browser engine. ", count: 12) + "</p>")
        case "/redirect":
            // Sends itself on by script, once loaded, with no click.
            return html("Redirect", "<script>addEventListener('load', () => setTimeout(() => location.replace('/page/after'), 50))</script>")
        case "/search":
            return html("Results", "<p>Results for \(request.queryItems?.first?.value ?? "")</p>")
        case "/icon.png": return ("200 OK", "image/png", icon)
        case "/filters.txt": return ("200 OK", "text/plain", filters)
        case "/download": return ("200 OK", "text/plain", Data("browser".utf8))
        case "/ad-banner.js": return ("200 OK", "text/javascript", Data("// an ad".utf8))
        default: return ("404 Not Found", "text/plain", Data("not found".utf8))
        }
    }

    private static let icon: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0 ..< 32 { for y in 0 ..< 32 { rep.setColor(.systemRed, atX: x, y: y) } }
        return rep.representation(using: .png, properties: [:])!
    }()

    /// The padding, and one rule a page here can run into.
    private static let filters = Data(((0 ..< ruleCount - 1).map { "||ad-\($0).invalid^" } + ["/ad-banner.js"]).joined(separator: "\n").utf8)
}
#endif
