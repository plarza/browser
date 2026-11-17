#if DEBUG
import AppKit
import BrowserKit

/// The address field: clicking in and out, typing, History's fill-in and
/// suggestions, and a file's path pasted in.
extension SelfTest {
    var addressCases: [Case] {
        [
            Case("address field") { await self.addressField() },
            Case("typing in the address field") { await self.typingInTheAddressField() },
            Case("a wipe while typing") { await self.wipeWhileTyping() },
            Case("words and no search engine") { await self.wordsAndNoSearchEngine() },
            Case("a link from another app") { await self.linkFromAnotherApp() },
            Case("a pasted file path") { await self.pastedFilePath() },
            Case("suggestions learn from picks") { await self.suggestionsLearn() },
        ]
    }

    private var field: AddressField { shell.sidebar.addressField }
    private var fieldEditor: NSTextView? { window.fieldEditor(true, for: field) as? NSTextView }

    private func addressField() async {
        let page = server.url("/page/WebKit-Test-Page")
        _ = await open(page)
        await click(field)
        let editor = { self.window.firstResponder as? NSTextView }
        await expect("click selects the whole address", {
            editor().map { $0.string == page.absoluteString && $0.selectedRange() == NSRange(location: 0, length: ($0.string as NSString).length) } == true
        }, "text=\(editor()?.string ?? "nil") selection=\(editor()?.selectedRange() ?? NSRange())")
        await click(selectedView)
        await expect("click on the page leaves the field", { !(window.firstResponder is NSTextView) && !field.isEditing })
        key("l")
        await expect("⌘L selects the whole address", {
            editor().map { $0.selectedRange().length == ($0.string as NSString).length && $0.string == page.absoluteString } == true
        })
        await click(selectedView)
        await expect("click on the page after ⌘L leaves the field", { !(window.firstResponder is NSTextView) })
    }

    private func typingInTheAddressField() async {
        _ = await open(server.url("/page/WebKit-Test-Page"))
        field.focus()
        let editor = fieldEditor
        editor?.selectAll(nil)
        await type("localh")
        await expect("typing fills in the rest of a visited site's name", {
            editor?.string == "localhost" && editor?.selectedRange() == NSRange(location: 6, length: 3)
        }, "text=\(editor?.string ?? "nil") selection=\(editor?.selectedRange() ?? NSRange())")
        await type("\u{7f}")
        check("Delete removes what was filled in", editor?.string == "localh", "text=\(editor?.string ?? "nil")")
        editor?.selectAll(nil)
        await type("webkit")
        let suggestions = field.suggestions
        await expect("history suggestions match by title", { suggestions.isShown && suggestions.visits.first?.title == "WebKit Test Page" })
        editor?.doCommand(by: #selector(NSResponder.moveUp(_:)))
        check("↑ goes to the bottom of the suggestions", suggestions.selected != nil && suggestions.selected == suggestions.visits.last,
              "selected=\(suggestions.selected?.url ?? "none")")
        editor?.doCommand(by: #selector(NSResponder.moveDown(_:)))
        check("↓ from the bottom comes back to what was typed", suggestions.selected == nil)
        await shot("suggest")
        window.makeFirstResponder(nil)
        check("leaving the field hides the suggestions", !suggestions.isShown || suggestions.alphaValue < 1)
    }

    /// A page that sends itself to another site is wiped: a new web view
    /// takes its place. The person typing in the field goes on typing.
    private func wipeWhileTyping() async {
        let tab = await open(server.url("/page/one"))
        let before = tab.webView
        key("l")
        await type("abc")
        let elsewhere = server.url("/page/three", on: server.other)
        await go(tab, elsewhere) { run(tab, "location.href = '\(elsewhere.absoluteString)'") }
        check("the page wiped itself into a new web view", tab.webView !== before)
        check("the address field keeps the keyboard, and what was typed", field.isEditing && editor(of: field)?.string == "abc",
              "editing=\(field.isEditing) text=\(editor(of: field)?.string ?? "nil")")
        await type("d")
        check("typing goes on in the field", editor(of: field)?.string == "abcd", "text=\(editor(of: field)?.string ?? "nil")")
        editor(of: field)?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await expect("Escape then gives the keyboard to the new page", { window.firstResponder === tab.webView && !field.isEditing })
        check("…and the field shows where the tab went", field.stringValue == "127.0.0.1", "field=\(field.stringValue)")
    }

    /// Words go to the search engine, if there is one.
    private func wordsAndNoSearchEngine() async {
        guard let tab = browser.selected else { return }
        await shown()
        field.focus()
        await type("webkit engine")
        let results = server.url("/search?q=webkit%20engine")
        await go(tab, results) { editor(of: field)?.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        check("words typed in the field go to the search engine", tab.url == results, "url=\(tab.url?.absoluteString ?? "nil")")
        await expect("Return gives the keyboard to the page", { window.firstResponder === tab.webView && !field.isEditing })
        Preferences.shared.settings.searchTemplate = ""
        key("l")
        editor(of: field)?.selectAll(nil)
        await type("more words")
        editor(of: field)?.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        check("with no search engine set the field says so, and goes nowhere",
              field.placeholderString == "No search engine set (⌘,)" && field.isEditing && tab.url == results && !tab.isLoading,
              "placeholder=\(field.placeholderString ?? "nil") url=\(tab.url?.absoluteString ?? "nil")")
        window.makeFirstResponder(nil)
    }

    /// What macOS hands Browser when another app opens a link with it.
    private func linkFromAnotherApp() async {
        let one = server.url("/page/one"), two = server.url("/page/two")
        guard let blank = browser.selected, let app = NSApp.delegate as? AppDelegate else { return }
        await shown()
        await go(blank, one) { app.application(NSApp, open: [one]) }
        check("a link from another app loads in the blank tab showing", browser.tabs.count == 1 && blank.url == one)
        await expect("…and the page has the keyboard, not the address field", { window.firstResponder === blank.webView && !field.isEditing })
        app.application(NSApp, open: [two])
        await expect("with a page showing, it opens in a new tab in front", {
            browser.tabs.count == 2 && browser.selected !== blank && browser.selected?.url == two
        }, "tabs=\(browser.tabs.map { $0.url?.path ?? "blank" })")
    }

    private func pastedFilePath() async {
        let one = server.url("/page/one")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Browser Local \(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("more"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let dot = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try? dot.write(to: folder.appendingPathComponent("dot.png"))
        try? "<title>Local</title><img id=dot src=dot.png>".write(to: folder.appendingPathComponent("map.html"), atomically: true, encoding: .utf8)
        try? "<title>More</title><img id=dot src=../dot.png>".write(to: folder.appendingPathComponent("more/page.html"), atomically: true, encoding: .utf8)
        let file = folder.appendingPathComponent("map.html"), more = folder.appendingPathComponent("more/page.html")
        let escaped = file.path.replacingOccurrences(of: " ", with: "\\ ")
        check("a path Terminal escaped is the same file",
              Address.resolve(escaped, searchTemplate: "") == .go(file) && Address.resolve("'\(file.path)'", searchTemplate: "") == .go(file),
              "escaped=\(String(describing: Address.resolve(escaped, searchTemplate: "")))")

        let tab = browser.newTab()
        await shown()
        field.focus()
        let editor = fieldEditor
        // The clipboard is whoever is at this Mac's: borrowed for the paste, then put back.
        let pasteboard = NSPasteboard.general
        let theirs = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: NSPasteboardItem()) { copy, type in
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
        }
        pasteboard.clearContents()
        pasteboard.setString(file.path, forType: .string)
        editor?.paste(nil)
        pasteboard.clearContents()
        pasteboard.writeObjects(theirs)
        await go(tab, file) { editor?.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        await expect("a pasted path opens the file, image and all", {
            await js(tab, "document.getElementById('dot').naturalWidth", in: .page) as? Int == 1
        })
        check("the field shows the file's path", field.stringValue == file.path, "field=\(field.stringValue)")
        await go(tab, more) { follow(tab, more) }
        await expect("a link from a local page opens another, with what's beside it", {
            await js(tab, "document.getElementById('dot').naturalWidth", in: .page) as? Int == 1
        })
        await go(tab, file) { tab.goBack() }
        let read = await js(tab, "fetch('dot.png').then(r => r.text()).then(() => 'read', () => 'blocked')", in: .page, awaiting: true) as? String
        check("a local page shows other files but can't read them", read == "blocked", "fetch=\(read ?? "nil")")

        await go(tab, one) { tab.load(one) }
        run(tab, "location.href = '\(file.absoluteString)'")
        // Nothing to wait for but nothing happening: long enough for a load to have begun.
        _ = await until("a file navigation that must not come", seconds: 1) { tab.url != one || tab.isLoading }
        check("a web page can't open a file on this Mac", tab.url == one && tab.webView.url == one, "url=\(tab.webView.url?.absoluteString ?? "nil")")
    }

    private func suggestionsLearn() async {
        let one = server.url("/page/one"), two = server.url("/page/two")
        for _ in 0 ..< 3 { _ = await open(one) }
        _ = await open(two)
        let suggestions = field.suggestions
        let editor = fieldEditor
        field.focus()
        editor?.selectAll(nil)
        await type("pag")
        await expect("the page visited most comes first", { suggestions.visits.first?.url == one.absoluteString },
                     "first=\(suggestions.visits.first?.url ?? "none")")
        guard let picked = suggestions.visits.first(where: { $0.url == two.absoluteString }) else {
            return check("the other page is listed too", false, "rows=\(suggestions.visits.map(\.url))")
        }
        guard let tab = browser.selected else { return }
        await go(tab, two) { suggestions.onPick(picked) }
        field.focus()
        editor?.selectAll(nil)
        await type("pa")
        await expect("a page picked after typing more comes first", { suggestions.visits.first?.url == two.absoluteString },
                     "first=\(suggestions.visits.first?.url ?? "none")")
        window.makeFirstResponder(nil)
    }
}
#endif
