#if DEBUG
import AppKit
import BrowserKit
import WebKit

/// What Browser asks of the system WebKit, seen from inside a page.
extension SelfTest {
    var webKitCases: [Case] {
        [Case("system WebKit") { await self.systemWebKit() }]
    }

    private func systemWebKit() async {
        let tab = await open(server.url("/page/WebKit-Test-Page"))
        let pool = (tab.webView.configuration.value(forKey: "processPool") as? NSObject)?.value(forKey: "_configuration") as? NSObject
        check("WebKit's JIT policy is enabled", pool?.value(forKey: "JITEnabled") as? Bool == true)
        let policy = tab.webView.configuration.defaultWebpagePreferences.value(forKey: "_networkConnectionIntegrityPolicy") as? UInt
        check("baseline, fingerprinting and link protections are enabled without Private Relay", policy == 321,
              "policy=\(policy.map(String.init) ?? "nil")")
        let locale = await js(tab, "Intl.DateTimeFormat().resolvedOptions().timeZone + ' ' + navigator.language", in: .page) as? String
        check("pages use UTC and en-US", locale == "UTC en-US", locale ?? "nil")
        let worker = await js(tab, """
        new Promise((resolve, reject) => {
            const url = URL.createObjectURL(new Blob(["postMessage(Intl.DateTimeFormat().resolvedOptions().timeZone + ' ' + navigator.language)"], {type: 'text/javascript'}));
            const worker = new Worker(url);
            worker.onmessage = event => { worker.terminate(); URL.revokeObjectURL(url); resolve(event.data); };
            worker.onerror = reject;
        })
        """, in: .page, awaiting: true) as? String
        check("workers use UTC and en-US", worker == "UTC en-US", worker ?? "nil")
        let wasm = await js(tab, """
        WebAssembly.instantiate(new Uint8Array([0,97,115,109,1,0,0,0,1,7,1,96,2,127,127,1,127,3,2,1,0,7,7,1,3,97,100,100,0,0,10,9,1,7,0,32,0,32,1,106,11])).then(result => result.instance.exports.add(20, 22))
        """, in: .page, awaiting: true) as? Int
        check("WebAssembly executes in the page", wasm == 42, "result=\(wasm ?? -1)")
    }
}
#endif
