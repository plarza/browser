import WebKit

/// GM_registerMenuCommand and GM_unregisterMenuCommand: the commands a
/// page's scripts put in the userscripts' button's menu.
@MainActor
final class GMMenuCommands {
    private let pages: UserscriptPages

    init(_ pages: UserscriptPages) {
        self.pages = pages
    }

    func register(_ call: UserscriptCall) {
        guard call.grants.contains("registermenucommand"), let page = page(of: call), let command = call.string("cmd") else { return }
        page.add(Userscripts.MenuCommand(id: "\(call.instance.id)/\(command)", caption: call.string("caption") ?? command,
                                         script: call.script.id, command: command, instance: call.instance))
    }

    func unregister(_ call: UserscriptCall) {
        guard call.grants.contains("unregistermenucommand"), let page = page(of: call), let command = call.string("cmd") else { return }
        page.remove(command, of: call.instance.id)
    }

    /// The page the call came from, if the copy that sent it is one that
    /// said it was running there.
    private func page(of call: UserscriptCall) -> UserscriptPage? {
        guard let webView = call.webView else { return nil }
        let page = pages.page(in: webView)
        return page.instances.contains { $0.id == call.instance.id } ? page : nil
    }
}
