#if DEBUG
import AppKit
import BrowserKit

/// Extensions' buttons. No extension is loaded (they belong to the apps on
/// this Mac, and would reach the internet): what is checked is that the
/// action bar hears of every change to which are on.
extension SelfTest {
    var extensionCases: [Case] {
        [Case("extensions' buttons") { await self.extensionButtons() }]
    }

    private func extensionButtons() async {
        let nobody = "network.aza.browser.selftest.no-such-extension"
        check("with no extension on there are no buttons", Extensions.shared.actions.isEmpty && Extensions.shared.enabled.isEmpty,
              "enabled=\(Extensions.shared.enabled)")
        // The way the action bar follows them: once now, and again after each change.
        var read = 0
        let following = Observer {
            _ = Extensions.shared.actions
            read += 1
        }
        defer { following.cancel() }
        await Extensions.shared.setEnabled(nobody, true)
        await expect("whoever reads the buttons is told when an extension is turned on", { read >= 2 }, "read=\(read)")
        check("an extension that isn't on this Mac gets no button", Extensions.shared.actions.isEmpty && Extensions.shared.enabled == [nobody])
        let saved = (try? Data(contentsOf: Store.url("extensions.json"))).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        check("which extensions are on is saved", saved == [nobody], "saved=\(saved ?? [])")
        await Extensions.shared.setEnabled(nobody, false)
        check("…and turning it off takes it out again", Extensions.shared.enabled.isEmpty)
        await shown()
        let buttons = shell.sidebar.actionBar.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        check("the action bar shows no button for it", buttons.isEmpty, "buttons=\(buttons.map { $0.toolTip ?? "?" })")
    }
}
#endif
