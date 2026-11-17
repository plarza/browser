#if DEBUG
import AppKit
import BrowserKit

/// Debug builds only: `-browserSelfTest YES` drives the real window with real
/// key and mouse events, through AppKit's own dispatch (menus, responders,
/// field editors), and logs PASS or FAIL for each thing a person would do.
///
/// Every page it loads comes from `TestServer`, on this Mac. It never sleeps
/// for a guessed time: each step waits until what it expects is true, and
/// says what it is waiting for when that takes more than two seconds. Each
/// case starts from a clean window, and a dialog left open fails it.
///
/// The cases are in Tests/Cases, by area; what they share is here (the
/// run, the checks), in Events.swift (keys and the mouse) and in Pages.swift
/// (loading pages and running script in them).
@MainActor
final class SelfTest {
    /// One thing a person would do, checked from a clean window.
    struct Case {
        let name: String
        let run: @MainActor () async -> Void

        init(_ name: String, _ run: @escaping @MainActor () async -> Void) {
            self.name = name
            self.run = run
        }
    }

    let shell: BrowserWindowController
    let window: NSWindow
    let server: TestServer
    var browser: Browser { shell.browser }
    private var passed = 0, failed = 0

    private init(shell: BrowserWindowController, window: NSWindow, server: TestServer) {
        self.shell = shell
        self.window = window
        self.server = server
    }

    private var cases: [Case] {
        webKitCases + addressCases + sidebarCases + identityCases + pageCases + ownPageCases
            + blockingCases + downloadCases + userscriptCases + extensionCases
    }

    // MARK: Launch

    static var enabled: Bool { OutOfTheWay.enabled }
    private static var server: TestServer?

    /// Before anything starts: the local site, and settings pointing at it,
    /// so not even the launch's filter-list fetch reaches the internet.
    static func prepare() {
        guard enabled else { return }
        let server = TestServer()
        self.server = server
        Preferences.shared.settings = settings(for: server)
    }

    /// Runs every case (or `-browserSelfTestOnly <case>`, just that one),
    /// then quits: exit status 0 only if every check passed.
    static func start(_ shell: BrowserWindowController) {
        guard enabled, let window = shell.window, let server else { return }
        let test = SelfTest(shell: shell, window: window, server: server)
        Task {
            await test.run(only: UserDefaults.standard.string(forKey: "browserSelfTestOnly"))
            NSLog("Browser self-test: done, \(test.passed) passed, \(test.failed) failed")
            exit(test.failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
        }
    }

    private static func settings(for server: TestServer) -> Settings {
        var settings = Settings()
        settings.filterLists = [server.url("/filters.txt").absoluteString]
        settings.searchTemplate = server.site + "/search?q=%s"
        return settings
    }

    // MARK: Running

    private func run(only: String?) async {
        let chosen = cases.filter { only == nil || $0.name == only }
        if chosen.isEmpty { check("there is a case called \(only ?? "")", false, "cases: \(cases.map(\.name).joined(separator: ", "))") }
        for test in chosen {
            await reset()
            // A case that never finishes fails, and the next one runs.
            var finished = false
            let running = Task {
                await test.run()
                finished = true
            }
            if !(await until("the \(test.name) case to finish", seconds: 240) { finished }) {
                running.cancel()
                check("the \(test.name) case finishes", false, "")
            }
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
                check("\(test.name): no dialog left open", false, "")
            }
        }
    }

    /// One blank tab, the test's settings, nothing in History, Downloads or any field.
    private func reset() async {
        for tab in browser.tabs { browser.close(tab) }
        Preferences.shared.settings = SelfTest.settings(for: server)
        History.shared.clear()
        HistoryModel.shared.query = ""
        Downloads.shared.dismissAllForTesting()
        for script in Userscripts.shared.scripts { Userscripts.shared.remove(script.id) }
        UserscriptsModel.shared.drafts = [:]
        UserscriptsModel.shared.errors = [:]
        // Nothing the last case started still running into this one.
        await until("icon fetches to finish") { !Favicons.shared.isFetching }
        if !shell.sidebar.isShown { shell.sidebar.toggle() }
        await shown()
        window.makeFirstResponder(nil)
    }

    // MARK: Checks

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1 }
        NSLog("Browser self-test: \(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " — \(detail())")")
    }

    /// Waits until `condition` holds, checking every 10 ms, for at most
    /// `seconds`; after two seconds it says what it is waiting for.
    @discardableResult
    func until(_ what: String, seconds: Double = 15, _ condition: () async -> Bool) async -> Bool {
        await Tooling.until(what, seconds: seconds, condition)
    }

    /// A check that may take a moment to come true.
    func expect(_ name: String, seconds: Double = 15, _ condition: () async -> Bool, _ detail: @autoclosure () -> String = "") async {
        check(name, await until(name, seconds: seconds, condition), detail())
    }

    /// The window follows the browser a moment after it changes: waits
    /// until it shows the selected tab, and a row for every tab.
    func shown() async {
        await until("the window to show the selected tab") {
            shell.pageArea.stage.page === browser.selected?.view && shell.sidebar.tabList.table.numberOfRows == browser.tabs.count
        }
    }

    /// `-browserShots <folder>`: the window as it is now, as `name`.png.
    func shot(_ name: String) async {
        await Shots.take(name, of: shell)
    }
}
#endif
