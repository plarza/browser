#if DEBUG
import AppKit
import BrowserKit

/// Userscripts: installing from a link, running with the GM APIs, the
/// userscripts' button, about://userscripts, switching off and updating;
/// and the APIs that answer later.
extension SelfTest {
    var userscriptCases: [Case] {
        [
            Case("userscripts") { await self.userscripts() },
            Case("userscript APIs") { await self.userscriptAPIs() },
        ]
    }

    private func userscripts() async {
        let one = server.url("/page/one"), two = server.url("/page/two")
        let bar = shell.pageArea.installBar, actionBar = shell.sidebar.actionBar
        check("with no script installed there is no userscripts' button", actionBar.scripts.isHidden)
        let installer = await open(server.url("/test.user.js"))
        await expect("a .user.js file shows with an install bar", {
            !bar.isHidden && bar.button.title == "Install" && bar.button.isEnabled
        }, "hidden=\(bar.isHidden) button=\(bar.button.title)")
        check("the bar names the script, its version and its sites", bar.detailText == "1.0 · Runs on localhost", "detail=\(bar.detailText)")
        check("the page scrolls under the bar", installer.webView.obscuredContentInsets.top == InstallBar.height)
        await shot("userscripts-install")
        await click(bar.button)
        await expect("Install installs it, with its @require and @resource", {
            let script = Userscripts.shared.scripts.first
            return script?.name == "Self Test" && script?.requires.count == 1 && script?.resources["note"] != nil
        }, "scripts=\(Userscripts.shared.scripts.map(\.name)) bar=\(bar.button.title) \(bar.detailText)")
        await expect("the bar then says it's installed", { bar.button.title == "Open Userscripts" })
        guard let id = Userscripts.shared.scripts.first?.id else { return }
        await expect("the userscripts' button appears once a script is installed", { !actionBar.scripts.isHidden })

        let page = await open(one)
        check("another tab's page has no install bar", bar.isHidden)
        var seen = ""
        await expect("it runs on a page it matches, with @require, @resource and GM_getValue", {
            seen = await dataset(page, "userscript")
            return seen == "ran 0 required note-text"
        }, "got=\(seen)")
        await expect("GM.xmlHttpRequest reaches another origin", {
            seen = await dataset(page, "xhr")
            return seen == "ok"
        }, "got=\(seen)")
        check("the script's variables stay out of the page",
              await js(page, "typeof requiredValue + ' ' + typeof GM_getValue", in: .page) as? String == "undefined undefined")
        await expect("its menu command is listed for the page", {
            Userscripts.shared.scripts(on: page.webView).first?.commands.map(\.caption) == ["Mark"]
        })
        await expect("the userscripts button counts it", { !actionBar.scripts.isHidden && actionBar.running == 1 }, "running=\(actionBar.running)")
        if let command = Userscripts.shared.scripts(on: page.webView).first?.commands.first {
            Userscripts.shared.perform(command, in: page.webView)
        }
        await expect("running the command reaches the script", { await dataset(page, "menu") == "clicked" })
        let forged = await js(page, """
        window.webkit.messageHandlers.browserUserscripts.postMessage({s: 'guess', id: '\(id)', op: 'setValue', args: {key: 'runs', value: '100'}}).then(() => 'accepted', () => 'refused')
        """, in: .page, awaiting: true) as? String
        check("a page can't send the scripts' messages", forged == "refused" && Userscripts.shared.values(of: id)["runs"] == "1",
              "forged=\(forged ?? "nil") runs=\(Userscripts.shared.values(of: id)["runs"] ?? "nil")")

        let next = await open(two)
        await expect("its values carry to a page in a fresh identity", { await dataset(next, "userscript") == "ran 1 required note-text" })
        let elsewhere = await open(server.url("/page/one", on: server.other))
        await expect("the button counts none on a page the script doesn't match", { actionBar.running == 0 && !actionBar.scripts.isHidden },
                     "running=\(actionBar.running)")
        browser.select(page)
        await expect("…and counts it again back on a page it ran on", { actionBar.running == 1 }, "running=\(actionBar.running)")
        browser.close(elsewhere)

        shell.commands.showUserscripts(nil)
        await expect("about://userscripts opens", { shell.pageArea.shownPage == .userscripts }, "page=\(String(describing: shell.pageArea.shownPage))")
        let host = shell.pageArea.pageHost
        let code = { self.views(CodeTextView.self, in: host).first }
        await expect("it shows the script's code", { code()?.string.contains("@name        Self Test") == true })
        await shot("userscripts-page")
        if let code = code() {
            window.makeFirstResponder(code)
            code.setSelectedRange(NSRange(location: (code.string as NSString).length, length: 0))
            await type("// edited")
            key("s")
            await expect("⌘S in the editor saves the script", {
                Userscripts.shared.script(id)?.source.hasSuffix("// edited") == true && Userscripts.shared.script(id)?.edited == true
            })
            check("…and doesn't hide the sidebar", shell.sidebar.isShown)
        }
        do {
            try await Userscripts.shared.save(id, source: "// ==UserScript==\n// @name Self Test\n// ==/UserScript==\nfunction (")
            check("a script that doesn't parse isn't saved", false, "it was saved")
        } catch {
            check("a script that doesn't parse isn't saved", Userscripts.shared.script(id)?.source.hasSuffix("// edited") == true, "\(error)")
        }

        Userscripts.shared.setEnabled(id, false)
        let off = await open(one)
        check("a script switched off doesn't run", await dataset(off, "userscript") == "none")

        let old = "// ==UserScript==\n// @name Updater\n// @version 1.0\n// @updateURL \(server.url("/update.user.js"))\n// @grant none\n// ==/UserScript==\n"
        _ = try? await Userscripts.shared.install(old, from: nil)
        await Userscripts.shared.checkForUpdates()
        let version = Userscripts.shared.scripts.first { $0.name == "Updater" }?.meta.version
        check("a newer @version from its @updateURL installs itself", version == "2.0", "version=\(version ?? "none")")
    }

    /// A script for one page of the test's site.
    private func script(_ name: String, _ path: String, _ lines: [String], _ code: String) -> String {
        (["// ==UserScript==", "// @name \(name)", "// @match http://localhost\(path)"] + lines + ["// ==/UserScript==", code]).joined(separator: "\n")
    }

    /// The APIs that answer later: a request's events, a tab a script opened
    /// closing, window.close and window.focus, a download; @unwrap; and
    /// Violentmonkey's backup.
    private func userscriptAPIs() async {
        let one = server.url("/page/one")
        let sources = [
            script("Events", "/page/events", ["// @grant GM_xmlhttpRequest"], """
            const seen = [];
            GM_xmlhttpRequest({url: '/big', onreadystatechange: r => seen.push('rs' + r.readyState),
              onprogress: r => seen.push(r.loaded > 0 && r.total === 300000 ? 'p+' : 'p0'),
              onload: r => { seen.push('load ' + r.responseText.length); document.documentElement.dataset.events = seen.join(','); }});
            GM_xmlhttpRequest({url: '/moved', redirect: 'manual', onload: r => { document.documentElement.dataset.redirect = String(r.status); }});
            """),
            script("Opener", "/page/opener", ["// @grant GM_openInTab"], """
            const tab = GM_openInTab(location.origin + '/page/closer', {active: false});
            tab.onclose = () => { document.documentElement.dataset.closed = String(tab.closed); };
            """),
            script("Closer", "/page/closer", ["// @grant window.close"], "setTimeout(() => window.close(), 100);"),
            script("Shutter", "/page/shutter", ["// @grant GM_openInTab"], """
            const tab = GM_openInTab(location.origin + '/page/shut', {active: true});
            tab.onclose = () => { document.documentElement.dataset.shut = String(tab.closed); };
            document.documentElement.dataset.opened = String(tab.closed);
            addEventListener('browser-test-shut', () => tab.close());
            """),
            script("Focuser", "/page/focuser", ["// @grant window.focus"], """
            let ok = window.document === document && typeof window.setTimeout === 'function';
            try { window.addEventListener('browser-test', () => {}); } catch (e) { ok = false; }
            document.documentElement.dataset.window = String(ok);
            window.focus();
            """),
            script("Ungranted", "/page/ungranted", ["// @grant GM_getValue"], """
            document.documentElement.dataset.ungranted = typeof GM_openInTab + ' ' + typeof GM_download;
            """),
            script("Downloader", "/page/downloader", ["// @grant GM_download"], """
            GM_download({url: '/download', name: 'gm-saved.txt', onload: () => { document.documentElement.dataset.download = 'loaded'; },
              onerror: e => { document.documentElement.dataset.download = 'error ' + e.error; }});
            """),
            script("Unwrapped", "/page/unwrapped", ["// @unwrap"], "var unwrappedGlobal = 42;"),
        ]
        for source in sources {
            do { try await Userscripts.shared.install(source, from: server.url("/")) } catch { check("installs \(source.prefix(40))", false, "\(error)") }
        }
        let paths = { self.browser.tabs.compactMap { $0.url?.path } }

        let events = await open(server.url("/page/events"))
        var seen = ""
        await expect("GM_xmlhttpRequest reports headers, then progress, then the load", {
            seen = await dataset(events, "events")
            return seen.hasPrefix("rs2") && seen.contains("p+") && seen.hasSuffix("rs4,load 300000")
        }, "events=\(seen)")
        await expect("redirect: 'manual' hands back the redirect itself", { await dataset(events, "redirect") == "301" })

        let opener = await open(server.url("/page/opener"))
        await expect("a tab GM_openInTab opened closes itself with window.close, and onclose hears it", {
            seen = await dataset(opener, "closed")
            return seen == "true"
        }, "closed=\(seen) tabs=\(paths())")
        check("…and the tab has gone", !paths().contains("/page/closer"), "tabs=\(paths())")
        check("a tab opened with active: false opens behind the page", browser.selected === opener)

        let shutter = await open(server.url("/page/shutter"))
        await expect("GM_openInTab with active: true brings its tab to the front", { browser.selected?.url?.path == "/page/shut" }, "tabs=\(paths())")
        check("what it returns says the tab is open", await dataset(shutter, "opened") == "false")
        run(shutter, "dispatchEvent(new Event('browser-test-shut'))")
        await expect("close() on what GM_openInTab returned closes that tab, and onclose hears it", {
            seen = await dataset(shutter, "shut")
            return seen == "true" && !paths().contains("/page/shut")
        }, "shut=\(seen) tabs=\(paths())")
        await expect("…and the page that opened it shows again", { browser.selected === shutter })

        let behind = browser.newTab(server.url("/page/focuser"), select: false)
        await expect("window.focus brings its tab to the front", { browser.selected === behind })
        await expect("the script's own window still works as the page's", { await dataset(behind, "window") == "true" })

        let ungranted = await open(server.url("/page/ungranted"))
        await expect("a script gets only the APIs it @grants", { await dataset(ungranted, "ungranted") == "undefined undefined" })

        let saved = Store.url("gm-saved.txt")
        try? FileManager.default.removeItem(at: saved)
        let downloader = await open(server.url("/page/downloader"))
        await expect("GM_download saves under the name it gives, and onload hears it", {
            seen = await dataset(downloader, "download")
            return seen == "loaded" && FileManager.default.fileExists(atPath: saved.path)
        }, "download=\(seen)")
        check("…through Browser's own downloads", Downloads.shared.items.first?.name == "gm-saved.txt" && Downloads.shared.items.first?.state == .finished,
              "items=\(Downloads.shared.items.prefix(2).map { "\($0.name) \($0.state)" })")

        let unwrapped = await open(server.url("/page/unwrapped"))
        await expect("an @unwrap script runs at the page's top level", {
            await js(unwrapped, "String(window.unwrappedGlobal)", in: .page) as? String == "42"
        })
        await expect("…and counts as running", { Userscripts.shared.scripts(on: unwrapped.webView).contains { $0.script.name == "Unwrapped" && $0.running } })
        await go(unwrapped, one) { follow(unwrapped, one) }
        check("…and not on the next page in the same web view", await js(unwrapped, "typeof unwrappedGlobal", in: .page) as? String == "undefined")

        await violentmonkeyBackup()
    }

    /// Violentmonkey's backup: its manifest, and the script beside it.
    private func violentmonkeyBackup() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vm-backup-" + UUID().uuidString)
        let zip = folder.appendingPathExtension("zip")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: zip)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("// ==UserScript==\n// @name Imported\n// @namespace imp\n// @match https://example.com/*\n// ==/UserScript==\n".utf8)
            .write(to: folder.appendingPathComponent("Imported.user.js"))
        try? Data(#"{"scripts":{"Imported":{"config":{"enabled":0,"shouldUpdate":0},"position":1}},"values":{"imp:Imported:":{"count":"n7","word":"shello","obj":"o{\"a\":1}","plain":"[1,2]"}}}"#.utf8)
            .write(to: folder.appendingPathComponent("violentmonkey"))
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", folder.path, zip.path]
        try? ditto.run()
        ditto.waitUntilExit()
        let result = await Userscripts.shared.importFiles([zip])
        let imported = Userscripts.shared.scripts.first { $0.name == "Imported" }
        let values = imported.map { Userscripts.shared.values(of: $0.id) } ?? [:]
        check("Violentmonkey's backup imports its scripts, switches, updates and values",
              result.count == 1 && imported?.enabled == false && imported?.edited == true
                && values == ["count": "7", "word": "\"hello\"", "obj": #"{"a":1}"#, "plain": "[1,2]"],
              "result=\(result) enabled=\(String(describing: imported?.enabled)) values=\(values)")
    }
}
#endif
