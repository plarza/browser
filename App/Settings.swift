import AppKit
import CoreKit
import SwiftUI

/// The four settings: search engine, cookie whitelist, filter lists,
/// extensions. Nothing here switches a protection off.
@MainActor
final class SettingsWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Settings"
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        window.isRestorable = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct SettingsView: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var whitelist = ""
    @State private var lists = ""

    private static let engines: [(String, String)] = [
        ("Mullvad Leta", "https://leta.mullvad.net/search?q=%s"),
        ("DuckDuckGo", "https://duckduckgo.com/?q=%s"),
        ("Brave Search", "https://search.brave.com/search?q=%s"),
        ("Startpage", "https://www.startpage.com/do/search?query=%s"),
        ("Kagi", "https://kagi.com/search?q=%s"),
    ]

    var body: some View {
        Form {
            Section {
                TextField("Search URL", text: $prefs.settings.searchTemplate, prompt: Text("https://example.com/search?q=%s"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    ForEach(Self.engines, id: \.1) { engine in
                        Button(engine.0) { prefs.settings.searchTemplate = engine.1 }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Search engine")
            } footer: {
                Text("`%s` is where your words go. Bangs like `!w` or `!gh` work with or without one.")
                    .foregroundStyle(.secondary).font(.caption)
            }

            Section {
                TextEditor(text: $whitelist)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 90)
                    .onChange(of: whitelist) { _, text in
                        prefs.settings.whitelist = text.split(whereSeparator: \.isNewline).map(String.init)
                    }
            } header: {
                Text("Keep cookies for")
            } footer: {
                Text("One domain per line; its subdomains are included. These sites keep cookies and storage on disk, shared by every tab, with one fixed fingerprint. Everything else is wiped on every load.")
                    .foregroundStyle(.secondary).font(.caption)
            }

            Section {
                TextEditor(text: $lists)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 140)
                HStack {
                    Button("Save and fetch now") {
                        prefs.settings.filterLists = lists.split(whereSeparator: \.isNewline)
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        Blocker.shared.refresh(force: true)
                    }
                    Button("Defaults") { lists = Settings.defaultFilterLists.joined(separator: "\n") }
                    Spacer()
                    BlockerStatus()
                }
            } header: {
                Text("Filter lists")
            } footer: {
                Text("Fetched once a day, with no cookies, and compiled into the engine's own blocker.")
                    .foregroundStyle(.secondary).font(.caption)
            }

            Section {
                Text("Extensions arrive with the next build: WebKit's extension engine, installed from a Chrome Web Store link, as in Search.")
                    .foregroundStyle(.secondary).font(.caption)
            } header: {
                Text("Extensions")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            whitelist = prefs.settings.whitelist.joined(separator: "\n")
            lists = prefs.settings.filterLists.joined(separator: "\n")
        }
    }
}

private struct BlockerStatus: View {
    @State private var text = ""
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .onReceive(timer) { _ in
                let blocker = Blocker.shared
                text = blocker.trouble ?? (blocker.ruleCount > 0 ? "\(blocker.ruleCount.formatted()) rules" : "")
            }
    }
}
