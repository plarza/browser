import BrowserKit
import SwiftUI

/// about://help: Browser's own pages, and what each gesture does. There
/// are no buttons for these, so this is where they are written down.
struct HelpScreen: View {
    let show: (InternalPage) -> Void

    private static let gestures: [(what: String, how: String)] = [
        ("Back", "Swipe from the left edge"),
        ("Forward", "Swipe from the right edge"),
        ("Reload", "Pull the page down"),
        ("Next or previous tab", "Swipe the address bar sideways"),
        ("All tabs", "Tap the stack, or drag the address bar up"),
        ("New tab", "Tap +"),
        ("Close a tab", "Swipe its card sideways, or tap its ✕"),
        ("Persist, Reload, Copy Link, Find on Page, Share", "Long press the address bar"),
        ("Persist or close a tab", "Long press its card"),
    ]

    var body: some View {
        List {
            Section("Browser Pages") {
                ForEach([InternalPage.history, .downloads, .settings], id: \.self) { page in
                    Button {
                        show(page)
                    } label: {
                        LabeledContent(page.title) {
                            Text(verbatim: page.url.absoluteString).font(.footnote.monospaced())
                        }
                    }
                    .tint(.primary)
                }
            }
            Section("Gestures") {
                ForEach(HelpScreen.gestures, id: \.what) { gesture in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gesture.what)
                        Text(gesture.how).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
