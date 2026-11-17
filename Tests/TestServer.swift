#if DEBUG
import Foundation
import Network

/// The self-test's own web site, on this Mac: every page, icon, redirect,
/// download and filter list the test loads, so it never waits on the
/// internet. Plain HTTP on loopback (which Browser doesn't upgrade), local
/// connections only, on a port the system picks. What it serves is in
/// `TestSite`.
final class TestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "browser.selftest.server")
    let port: UInt16

    /// Two sites on one server: two hosts, so two origins and two jars.
    var site: String { "http://localhost:\(port)" }
    var other: String { "http://127.0.0.1:\(port)" }
    func url(_ path: String, on base: String? = nil) -> URL { URL(string: (base ?? site) + path)! }

    init() {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        let listener = try! NWListener(using: parameters, on: .any)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            TestServer.serve(connection, received: Data())
        }
        listener.start(queue: queue)
        ready.wait()
        port = listener.port!.rawValue
    }

    /// Reads a request's head, then answers it and hangs up.
    private static func serve(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { chunk, _, done, error in
            let data = received + (chunk ?? Data())
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
                if done || error != nil { connection.cancel() } else { serve(connection, received: data) }
                return
            }
            let target = String(decoding: data[..<end.lowerBound], as: UTF8.self).split(separator: " ").dropFirst().first ?? "/"
            let response = TestSite.respond(to: URLComponents(string: String(target)) ?? URLComponents())
            var head = "HTTP/1.1 \(response.status)\r\nContent-Type: \(response.type)\r\nCache-Control: no-store\r\n"
            for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
            if let promised = response.promised {
                // A big file that sends its first part and then waits, for
                // cancelling partway: the connection stays open until Browser drops it.
                head += "Content-Length: \(promised)\r\n\r\n"
                connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in })
            } else {
                head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + response.body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
#endif
