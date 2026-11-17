import BrowserKit
import UIKit
import WebKit

/// What BrowserKit asks of the app around it, answered on the iPhone.
extension ScreenController: Shell {
    func tab(_ tab: Tab, didReplace old: WKWebView?) {
        pages.prepare(tab.webView)
    }

    func confirmClosing(_ tab: Tab) async -> Bool {
        await alerts.ask("Close “\(tab.cardTitle)”?", detail: "Its cookies and site data will be deleted.", yes: "Close Tab", destructive: true)
    }

    func tab(_ tab: Tab, allowCapture type: WKMediaCaptureType, for origin: String) async -> Bool {
        let what = switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        default: "camera and microphone"
        }
        return await alerts.ask("\(origin) wants to use your \(what).", yes: "Allow", no: "Don’t Allow")
    }

    /// Downloads go to `Downloads` in Browser's own folder in the Files app.
    func tab(_ tab: Tab, saveDownload name: String) async -> URL? {
        let file = DownloadsFolder.place(for: name)
        messages.say("Downloading \(file.lastPathComponent)")
        return file
    }

    func tab(_ tab: Tab, runAlert message: String) async {
        await alerts.tell(message, from: tab)
        pages.answered()
    }

    func tab(_ tab: Tab, runConfirm message: String) async -> Bool {
        let answer = await alerts.ask(Alerts.title(for: tab), detail: message)
        pages.answered()
        return answer
    }

    func tab(_ tab: Tab, runPrompt message: String, defaultText: String?) async -> String? {
        let answer = await alerts.prompt(message, from: tab, defaultText: defaultText)
        pages.answered()
        return answer
    }

    var windowFrame: CGRect { view.window?.frame ?? .null }
}

/// Where downloads go: a folder the Files app shows under Browser.
enum DownloadsFolder {
    static var url: URL {
        URL.documentsDirectory.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    /// A file called `name` in the folder. A name already taken gets " 2",
    /// " 3" and so on before its extension.
    static func place(for name: String) -> URL {
        let folder = url
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let wanted = folder.appending(path: name.isEmpty ? "Download" : name)
        let base = wanted.deletingPathExtension().lastPathComponent, ending = wanted.pathExtension
        var file = wanted, number = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appending(path: ending.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ending)")
            number += 1
        }
        return file
    }
}
