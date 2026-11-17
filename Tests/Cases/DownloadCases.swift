#if DEBUG
import AppKit
import BrowserKit

/// Downloads: saving one, the rows at the foot of the sidebar,
/// about://downloads, and cancelling.
extension SelfTest {
    var downloadCases: [Case] {
        [
            Case("downloads") { await self.downloads() },
            Case("download image") { await self.downloadImage() },
            Case("cancel download") { await self.cancelDownload() },
            Case("download rows") { await self.downloadRowStates() },
        ]
    }

    private var rows: [DownloadRow] { shell.sidebar.downloadRows.rows }

    private func downloads() async {
        Downloads.shared.autoDismiss = 0.5
        defer { Downloads.shared.autoDismiss = 60 }
        let tab = await open(server.url("/page/one"))
        run(tab, "location.href = '/download'")
        await expect("a download saves where asked and shows in the sidebar", {
            let got = Downloads.shared.items.first
            return got?.name == "browser-test.txt" && got?.state == .finished && got.map { FileManager.default.fileExists(atPath: $0.file.path) } == true
        }, "items=\(Downloads.shared.items.map(\.name))")
        check("the page it came from stays where it was", tab.url == server.url("/page/one"), "url=\(tab.url?.absoluteString ?? "nil")")
        key("j")
        await expect("⌘J opens about://downloads", { shell.pageArea.shownPage == .downloads }, "page=\(String(describing: shell.pageArea.shownPage))")
        await expect("a done download leaves the sidebar by itself", { downloadRows == 0 })
        check("…and stays on about://downloads", Downloads.shared.items.first?.name == "browser-test.txt")
        await shot("downloads")
    }

    private func downloadImage() async {
        let tab = await open(server.url("/picture"))
        await expect("the picture loads", { await js(tab, "document.images[0].complete && document.images[0].naturalWidth", in: .page) as? Int == 32 })
        let view = tab.webView
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        await expect("the page is in front of the one it replaced", { window.contentView?.superview?.hitTest(point)?.isDescendant(of: view) == true })
        // The page's own context menu: Download Image, picked while it's open.
        let picked = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            // AppKit says so on the main thread, where the menu lives.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                if let index = menu?.items.firstIndex(where: { $0.title == "Download Image" }) { SelfTest.choose(itemAt: index) }
            }
        }
        defer { NotificationCenter.default.removeObserver(picked) }
        rightClick(at: point)
        await expect("Download Image on a picture saves it", {
            let got = Downloads.shared.items.first
            return got?.name == "icon.png" && got?.state == .finished && got.map { FileManager.default.fileExists(atPath: $0.file.path) } == true
        }, "items=\(Downloads.shared.items.map { "\($0.name) \($0.state)" })")
    }

    private func cancelDownload() async {
        let tab = await open(server.url("/page/one"))
        run(tab, "location.href = '/download-slow'")
        var item: Downloads.Item?
        await expect("a big download starts and shows in the sidebar", {
            item = Downloads.shared.items.first { $0.name == "browser-slow.bin" }
            return item.map { $0.state == .active && $0.received > 0 } == true && rows.count == 1
        })
        guard let item, let row = rows.first else { return }
        check("its row shows the size while it comes down", row.accessory == .size)
        row.hovering = true
        check("…and an x while the pointer is over it", row.accessory == .cancel)
        row.pressed()
        await expect("its x asks before cancelling", { window.attachedSheet != nil })
        escape()
        await expect("Escape keeps it downloading", { window.attachedSheet == nil })
        check("…and it is still downloading", item.state == .active, "state=\(item.state)")
        row.pressed()
        await expect("it asks again", { window.attachedSheet != nil })
        confirm("Cancel Download")
        await expect("Cancel Download stops it and takes it off the sidebar", {
            item.state == .cancelled && downloadRows == 0 && !FileManager.default.fileExists(atPath: item.file.path)
        }, "state=\(item.state)")
        check("about://downloads lists it as cancelled", Downloads.shared.items.contains { $0 === item && $0.state == .cancelled })
    }

    private func downloadRowStates() async {
        Downloads.shared.addForTesting(name: "Quarterly Report.pdf", received: 2_400_000, expected: 2_400_000, state: .finished)
        Downloads.shared.addForTesting(name: "ubuntu-26.04-desktop-arm64.iso", received: 1_900_000_000, expected: 6_100_000_000, state: .active)
        Downloads.shared.addForTesting(name: "photos-export.zip", received: 412_000_000, expected: 580_000_000, state: .active)
        await expect("the sidebar lists three downloads", { rows.count == 3 })
        let rows = rows
        rows.first?.hovering = true
        check("a downloading row shows its size, and an x while hovered; a done one a minus",
              rows.count == 3 && rows[0].accessory == .cancel && rows[1].accessory == .size && rows[2].accessory == .remove,
              "accessories=\(rows.map(\.accessory))")
        await shot("downloads-sidebar")
        rows.first?.hovering = false
        rows.last?.pressed()
        await expect("the minus takes a done download off the sidebar", { downloadRows == 2 })
    }
}
#endif
