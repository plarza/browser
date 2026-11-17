#if DEBUG
import AppKit
import BrowserKit

/// Debug builds only: `-browserProbe <url> -browserProbeOut <file>` loads
/// the page, lets it settle, writes what it shows; then reloads (a wipe)
/// and writes it again. `-browserProbeScript <js>`: writes what that
/// expression gives in the page's own world instead. The filter lists are
/// compiled first, and Browser quits when it is done.
@MainActor
enum Probe {
    /// The page to probe, if Browser was launched to probe one.
    static var address: String? { UserDefaults.standard.string(forKey: "browserProbe") }

    static func run(_ shell: BrowserWindowController) {
        let defaults = UserDefaults.standard
        guard let address, let url = URL(string: address), let out = defaults.string(forKey: "browserProbeOut") else { return }
        let script = defaults.string(forKey: "browserProbeScript")
        Task {
            await Tooling.until("the filter lists", seconds: 180) { Blocker.shared.ruleCount > 0 && !Blocker.shared.isRefreshing }
            let tab = shell.browser.newTab(url)
            var report = ""
            for pass in 1 ... 2 {
                try? await Task.sleep(for: .seconds(script == nil ? 35 : 12))
                let text = try? await tab.webView.evaluateJavaScript(script ?? "document.body.innerText", in: nil,
                                                                     contentWorld: script == nil ? .defaultClient : .page) as? String
                report += "===== PASS \(pass)\n\(text ?? "(nothing)")\n"
                try? report.write(toFile: out, atomically: true, encoding: .utf8)
                if pass == 1 { tab.reload() }
            }
            NSLog("Browser probe: done")
            exit(EXIT_SUCCESS)
        }
    }
}
#endif
