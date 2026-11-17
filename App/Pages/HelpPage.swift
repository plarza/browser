import AppKit
import BrowserKit
import SwiftUI

/// about://help: Browser's own pages and every keyboard shortcut, read
/// from the menus.
struct HelpPage: View {
    /// The shortcuts menu by menu, in the menu bar's order.
    private var sections: [(menu: String, shortcuts: [Shortcut])] {
        let shortcuts = NSApp.mainMenu.map { Shortcut.all(in: $0) } ?? []
        return shortcuts.reduce(into: []) { sections, shortcut in
            if sections.last?.menu == shortcut.menu {
                sections[sections.count - 1].shortcuts.append(shortcut)
            } else {
                sections.append((shortcut.menu, [shortcut]))
            }
        }
    }

    var body: some View {
        Form {
            // Browser's own pages: typed into the address field, or by their keys.
            Section("Browser Pages") {
                ForEach(InternalPage.allCases, id: \.self) { page in
                    LabeledContent(page.title) {
                        HStack(spacing: 10) {
                            Text(page.url.absoluteString)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Keys(text: NSApp.mainMenu.map { Shortcut.keys(for: Commands.showing(page), in: $0) } ?? "")
                        }
                    }
                }
            }
            ForEach(sections, id: \.menu) { section in
                Section(section.menu) {
                    ForEach(section.shortcuts, id: \.self) { shortcut in
                        LabeledContent(shortcut.title) { Keys(text: shortcut.keys) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .readableWidth()
    }

    /// A shortcut's keys as keycaps; "A or B" is two.
    private struct Keys: View {
        let text: String

        var body: some View {
            HStack(spacing: 4) {
                ForEach(text.isEmpty ? [] : text.components(separatedBy: " or "), id: \.self) { keys in
                    Text(keys)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }
}
