import AppKit
import BrowserKit

/// The userscripts' button's menu: the scripts for this page, on or off,
/// with a checkmark to switch each, and the commands of those running.
@MainActor
final class ScriptsMenu: NSObject {
    var onOpenUserscripts: () -> Void = {}
    private let browser: Browser

    init(browser: Browser) {
        self.browser = browser
    }

    func show(from button: NSView) {
        let menu = NSMenu()
        let page = browser.selected.flatMap { $0.page == nil ? $0.webView : nil }
        let scripts = Userscripts.shared.scripts(on: page)
        if scripts.isEmpty {
            menu.addItem(.sectionHeader(title: "No userscripts on this page"))
        } else {
            menu.addItem(.sectionHeader(title: "Userscripts on \(page?.url?.host ?? "this page")"))
            for item in scripts {
                let toggle = NSMenuItem(title: item.script.name, action: #selector(toggle(_:)), keyEquivalent: "")
                toggle.state = item.script.enabled ? .on : .off
                toggle.representedObject = item.script.id
                toggle.toolTip = item.script.enabled ? "Turn off. The page keeps it until it loads again." : "Turn on from the next load."
                menu.addItem(toggle)
                for command in item.commands {
                    let run = NSMenuItem(title: command.caption, action: #selector(run(_:)), keyEquivalent: "")
                    run.indentationLevel = 1
                    run.representedObject = command
                    menu.addItem(run)
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Userscripts", action: #selector(openUserscripts), keyEquivalent: ""))
        for item in menu.items where item.action != nil { item.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func toggle(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let script = Userscripts.shared.script(id) else { return }
        Userscripts.shared.setEnabled(id, !script.enabled)
    }

    @objc private func run(_ item: NSMenuItem) {
        guard let command = item.representedObject as? Userscripts.MenuCommand, let webView = browser.selected?.webView else { return }
        Userscripts.shared.perform(command, in: webView)
    }

    @objc private func openUserscripts() { onOpenUserscripts() }
}
