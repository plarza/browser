import Foundation
import WebKit

/// GM_xmlhttpRequest. The request goes from the app, so it isn't held to
/// CORS, with Safari's user agent and the tab's own cookies.
@MainActor
final class GMRequests {
    /// The requests under way, each by the id its script gave it, as the
    /// way to cancel it.
    private var cancels: [String: () -> Void] = [:]

    /// Makes the request and answers with its response, or with why there
    /// is none. On the way the script hears what happens as it happens, in
    /// order, and all of it before the answer: readyState 2 with the
    /// headers, then progress as the body arrives.
    func send(_ call: UserscriptCall) async throws(UserscriptRefusal) -> Any? {
        guard call.grants.contains("xmlhttprequest") else { throw .notGranted }
        guard let url = GMRequests.address(call) else { return ["error": "Only http and https addresses can be fetched."] }
        var request = GMRequests.request(to: url, call)
        // The tab's own cookies, as a browser's userscript manager sends
        // the browser's, unless the script asks for none.
        let jar = (call.arguments["anonymous"] as? Bool ?? false) ? nil : call.webView?.configuration.websiteDataStore.httpCookieStore
        if let jar, request.value(forHTTPHeaderField: "Cookie") == nil {
            let cookies = await GMRequests.cookies(in: jar, for: url)
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        }

        let id = call.string("reqId") ?? UUID().uuidString
        let transfer = Transfer(redirect: call.string("redirect") ?? "follow")
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Engine.sessionConfiguration(timeout: request.timeoutInterval), delegate: transfer, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        cancels[id] = { task.cancel() }
        defer { cancels[id] = nil }
        task.resume()

        func event(_ response: HTTPURLResponse?, _ fields: [String: Any]) -> [String: Any] {
            var event = response.map { GMRequests.describe($0, asked: url) } ?? [:]
            event["type"] = "xhr"
            event["reqId"] = id
            return event.merging(fields) { _, field in field }
        }
        // Progress reaches the script at most every 50 ms; the last of it
        // waits here in case nothing newer comes.
        var lastProgress = Date.distantPast
        var held: [String: Any]?
        for await happened in transfer.events {
            switch happened {
            case .response(let response):
                await call.instance.push(event(response, ["readyState": 2]))
            case .progress(let loaded, let total, let response):
                let progress = event(response, ["readyState": 3, "loaded": loaded, "total": total])
                if Date().timeIntervalSince(lastProgress) >= 0.05 {
                    lastProgress = Date()
                    held = nil
                    await call.instance.push(progress)
                } else {
                    held = progress
                }
            case .finished(let outcome):
                if let held { await call.instance.push(held) }
                return await GMRequests.answer(outcome, asked: url, jar: jar)
            }
        }
        return ["error": "No response"]
    }

    /// `abort()` on what GM_xmlhttpRequest returned.
    func abort(_ call: UserscriptCall) {
        if let id = call.string("reqId") { cancels.removeValue(forKey: id)?() }
    }

    // MARK: The request

    /// Where the request goes: HTTPS-only, as every load is, except to
    /// this Mac.
    private static func address(_ call: UserscriptCall) -> URL? {
        guard let url = call.url("url", schemes: ["https", "http"]) else { return nil }
        guard url.scheme?.lowercased() == "http", !Site.isLoopback(url.host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        parts.scheme = "https"
        if parts.port == 80 { parts.port = nil }
        return parts.url ?? url
    }

    private static func request(to url: URL, _ call: UserscriptCall) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = call.string("method") ?? "GET"
        let timeout = (call.arguments["timeout"] as? Double ?? 0) / 1000
        request.timeoutInterval = timeout > 0 ? timeout : 60
        for (name, value) in call.arguments["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        // Text as it is; anything else (a Blob, a buffer, a form) as its bytes.
        if let body = call.string("body") { request.httpBody = Data(body.utf8) }
        if let bytes = call.string("bodyB64") { request.httpBody = Data(base64Encoded: bytes) }
        if let user = call.string("user") {
            let pair = "\(user):\(call.string("password") ?? "")"
            request.setValue("Basic " + Data(pair.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The cookies in `jar` that a page's own request to `url` would carry.
    private static func cookies(in jar: WKHTTPCookieStore, for url: URL) async -> [HTTPCookie] {
        let host = url.host?.lowercased() ?? ""
        return await jar.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            let covers = domain.hasPrefix(".") ? host == domain.dropFirst() || host.hasSuffix(domain) : host == domain
            return covers && url.path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https")
        }
    }

    // MARK: The response

    private static func answer(_ outcome: Transfer.Outcome, asked url: URL, jar: WKHTTPCookieStore?) async -> [String: Any] {
        switch outcome {
        case .loaded(_, nil):
            return ["error": "No response"]
        case .loaded(let body, let response?):
            // Cookies it was sent go back into the tab's jar.
            if let jar, let from = response.url {
                let fields = response.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
                for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: from) { await jar.setCookie(cookie) }
            }
            var answer = describe(response, asked: url)
            answer["body"] = body.base64EncodedString()
            return answer
        case .refusedRedirect:
            return ["error": "Redirected, and the request asked not to follow."]
        case .failed(let error):
            return ["error": error.localizedDescription, "timeout": (error as? URLError)?.code == .timedOut]
        }
    }

    /// A response's status, address and headers, as the script reads them.
    private static func describe(_ response: HTTPURLResponse, asked url: URL) -> [String: Any] {
        let status = response.statusCode
        return [
            "status": status,
            "statusText": status == 200 ? "OK" : HTTPURLResponse.localizedString(forStatusCode: status).capitalized,
            "finalUrl": response.url?.absoluteString ?? url.absoluteString,
            "headers": response.allHeaderFields.map { "\(String(describing: $0.key).lowercased()): \($0.value)" }.sorted().joined(separator: "\r\n"),
        ]
    }
}

/// One request's delegate, on its session's own serial queue: it reports
/// what happens to the request, in the order it happens.
private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case response(HTTPURLResponse)
        case progress(loaded: Int64, total: Int64, HTTPURLResponse?)
        case finished(Outcome)
    }

    enum Outcome: Sendable {
        case loaded(Data, HTTPURLResponse?)
        case failed(any Error)
        /// `redirect: 'error'`, and the server redirected.
        case refusedRedirect
    }

    let events: AsyncStream<Event>
    private let report: AsyncStream<Event>.Continuation
    /// What the script asked for: `follow`, `manual` or `error`.
    private let redirect: String
    // Touched only on the session's queue.
    private var body = Data()
    private var response: HTTPURLResponse?
    private var expected: Int64 = -1
    private var refusedRedirect = false

    init(redirect: String) {
        self.redirect = redirect
        (events, report) = AsyncStream.makeStream(of: Event.self)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        expected = response.expectedContentLength
        if let response = self.response { report.yield(.response(response)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
        report.yield(.progress(loaded: Int64(body.count), total: expected, response))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        switch redirect {
        case "manual":
            // The redirect itself is the response.
            completionHandler(nil)
        case "error":
            refusedRedirect = true
            task.cancel()
            completionHandler(nil)
        default:
            completionHandler(request)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            report.yield(.finished(refusedRedirect ? .refusedRedirect : .failed(error)))
        } else {
            report.yield(.finished(.loaded(body, response)))
        }
        report.finish()
    }
}
