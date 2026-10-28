import AppKit
import BrowserKit
import SwiftUI

/// Browser's own pages, as native views in the tab: about://settings,
/// about://history and about://help.
@MainActor
enum Pages {
    static func view(_ page: String, open: @escaping (URL) -> Void) -> AnyView {
        switch page {
        case "settings": AnyView(SettingsPage())
        case "help": AnyView(HelpPage())
        case "downloads": AnyView(DownloadsPage())
        default: AnyView(HistoryPage(open: open))
        }
    }
}

extension Pages {
    /// Side margins that keep a page's content 720 points wide at most,
    /// with its scroll bar still at the window's edge.
    static func margin(_ width: CGFloat) -> CGFloat { max(24, (width - 720) / 2) }
}

extension View {
    func readableWidth() -> some View {
        GeometryReader { geometry in
            contentMargins(.horizontal, Pages.margin(geometry.size.width), for: .scrollContent)
        }
    }
}

// MARK: History

@MainActor
final class HistoryModel: ObservableObject {
    static let shared = HistoryModel()
    @Published var query = "" { didSet { refresh() } }
    @Published private(set) var results: [History.Visit] = []

    func refresh() { results = History.shared.search(query) }
}

struct HistoryPage: View {
    let open: (URL) -> Void
    @ObservedObject private var model = HistoryModel.shared

    var body: some View {
        GeometryReader { geometry in
            let margin = Pages.margin(geometry.size.width)
            VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(text: $model.query, placeholder: "Search History") {
                    if let first = model.results.first, let url = URL(string: first.url) { open(url) }
                }
                .controlSize(.large)
                Button("Clear History") {
                    Task {
                        guard await Dialogs.ask("Clear all history?", yes: "Clear History") else { return }
                        History.shared.clear()
                        model.refresh()
                    }
                }
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
            }
            .padding(.horizontal, margin + 16)
            .padding(.vertical, 16)
            if model.results.isEmpty {
                if model.query.isEmpty {
                    Spacer()
                } else {
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.results, id: \.url) { visit in
                            HistoryRow(visit: visit, open: open)
                            Divider()
                        }
                    }
                }
                .contentMargins(.horizontal, margin + 16, for: .scrollContent)
            }
            }
        }
        .onAppear { model.refresh() }
    }
}

struct HistoryRow: View {
    let visit: History.Visit
    let open: (URL) -> Void
    @State private var hovering = false

    var body: some View {
        let bare = History.bare(visit.url)
        HStack(spacing: 10) {
            SiteIcon(url: URL(string: visit.url))
            VStack(alignment: .leading, spacing: 1) {
                Text(visit.title.isEmpty ? bare : visit.title).lineLimit(1)
                Text(bare).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Remove") {
                History.shared.remove(visit.url)
                HistoryModel.shared.refresh()
            }
            .buttonBorderShape(.capsule)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if let url = URL(string: visit.url) { open(url) } }
    }
}

struct SiteIcon: View {
    let url: URL?
    @State private var version = 0

    var body: some View {
        Group {
            if let icon = Favicons.shared.icon(for: url) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .id(version)
        .onAppear { if let url { Favicons.shared.fetch(site: url) } }
        .onReceive(NotificationCenter.default.publisher(for: Favicons.changed)) { _ in version += 1 }
    }
}

/// The address field's own control, AppKit's search field, for searching
/// a page of Browser's.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            MainActor.assumeIsolated { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            MainActor.assumeIsolated { parent.onSubmit() }
            return true
        }
    }
}

// MARK: Settings

/// The search engines offered with one click; their icons ship with Browser.
struct SearchEngine: Identifiable {
    let name: String
    let template: String
    let icon: String
    var id: String { name }

    static let all = [
        SearchEngine(name: "Google", template: "https://www.google.com/search?q=%s", icon: "google.png"),
        SearchEngine(name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%s", icon: "duckduckgo.png"),
        SearchEngine(name: "Brave", template: "https://search.brave.com/search?q=%s", icon: "brave.svg"),
        SearchEngine(name: "Startpage", template: "https://www.startpage.com/do/search?query=%s", icon: "startpage.png"),
        SearchEngine(name: "Kagi", template: "https://kagi.com/search?q=%s", icon: "kagi.png"),
    ]

    @MainActor func choose() { Preferences.shared.settings.searchTemplate = template }

    var image: NSImage? {
        Bundle.main.url(forResource: icon, withExtension: nil, subdirectory: "Engines").flatMap(NSImage.init(contentsOf:))
    }
}

struct SettingsPage: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var rules = Blocker.shared.ruleCount
    @State private var trouble: String?
    @State private var enabled = Extensions.shared.enabled
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Search Engine") {
                TextField("Search URL", text: $prefs.settings.searchTemplate, prompt: Text("https://example.com/search?q=%s"))
                    .labelsHidden()
                HStack {
                    ForEach(SearchEngine.all) { engine in
                        Button(action: engine.choose) {
                            Label {
                                Text(engine.name)
                            } icon: {
                                if let image = engine.image {
                                    Image(nsImage: image).resizable().frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                                }
                            }
                        }
                        .buttonBorderShape(.capsule)
                    }
                }
            }

            Section("Appearance") {
                Segmented(selection: $prefs.settings.appearance, [(.light, "Light"), (.dark, "Dark"), (.system, "System")])
            }

            Section("New Tabs Open") {
                Segmented(selection: $prefs.settings.newTabPosition, [(.below, "Below Current Tab"), (.top, "At the Top"), (.bottom, "At the Bottom")])
            }

            Section("New Tab Page") {
                Segmented(selection: $prefs.settings.newTabPage, [(.image, "Image"), (.color, "Color"), (.blank, "Blank")])
                switch prefs.settings.newTabPage {
                case .image:
                    HStack(spacing: 12) {
                        NewTabThumbnail(version: prefs.newTabImageVersion)
                        Button("Choose Image…", action: chooseImage).buttonBorderShape(.capsule)
                        if FileManager.default.fileExists(atPath: Settings.newTabImage.path) {
                            Button("Use Default") {
                                Task {
                                    guard await Dialogs.ask("Go back to the default image?", yes: "Use Default") else { return }
                                    try? FileManager.default.removeItem(at: Settings.newTabImage)
                                    prefs.newTabImageChanged()
                                }
                            }.buttonBorderShape(.capsule)
                        }
                    }
                case .color:
                    ColorPicker("Color", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: prefs.settings.newTabColor)) },
                        set: { prefs.settings.newTabColor = NSColor($0).hex }
                    ), supportsOpacity: false)
                case .blank:
                    EmptyView()
                }
                Toggle("Fill Behind Sidebar", isOn: $prefs.settings.fill)
                if prefs.settings.fill {
                    if prefs.settings.newTabPage == .image {
                        LabeledContent("Blur") { Notched(value: $prefs.settings.fillBlur) }
                    }
                    LabeledContent("Transparency") { Notched(value: $prefs.settings.fillTransparency) }
                }
            }

            Section("Keep Cookies For") {
                RowList(items: prefs.settings.whitelist, placeholder: "Add domain", icon: { URL(string: "https://\($0)") },
                        removal: { "Delete the cookies and data kept for \($0)?" },
                        normalise: { Whitelist.normalise([$0]).first }) { prefs.settings.whitelist = $0 }
            }

            Section("Filter Lists") {
                RowList(items: prefs.settings.filterLists, placeholder: "Add filter list URL", icon: { URL(string: $0) },
                        removal: { "Remove \($0)?" },
                        normalise: { URL(string: $0)?.scheme == "https" ? $0 : nil }) {
                    prefs.settings.filterLists = $0
                    Blocker.shared.refresh(force: true)
                }
                HStack {
                    Button("Update Now") { Blocker.shared.refresh(force: true) }.buttonBorderShape(.capsule)
                    Button("Defaults") {
                        Task {
                            guard await Dialogs.ask("Replace your filter lists with the defaults?", yes: "Replace") else { return }
                            prefs.settings.filterLists = Settings.defaultFilterLists
                            Blocker.shared.refresh(force: true)
                        }
                    }.buttonBorderShape(.capsule)
                    Spacer()
                    if rules > 0 { Text("\(rules.formatted()) rules").foregroundStyle(.secondary) }
                }
            }

            Section("Safari Extensions") {
                ForEach(Extensions.shared.found) { item in
                    Toggle(item.name, isOn: Binding(get: { enabled.contains(item.id) }, set: { on in
                        Task {
                            await Extensions.shared.setEnabled(item.id, on)
                            enabled = Extensions.shared.enabled
                        }
                    }))
                }
                if Extensions.shared.found.isEmpty {
                    Text("Safari extensions from apps in Applications show here.").foregroundStyle(.secondary)
                }
            }

            if let trouble {
                Text(trouble).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .readableWidth()
        .onReceive(tick) { _ in
            rules = Blocker.shared.ruleCount
            trouble = Blocker.shared.trouble ?? Extensions.shared.trouble
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        try? FileManager.default.removeItem(at: Settings.newTabImage)
        try? FileManager.default.copyItem(at: picked, to: Settings.newTabImage)
        prefs.settings.newTabPage = .image
        prefs.newTabImageChanged()
    }
}

/// A list edited a row at a time: each row with its site's icon and a ✕
/// that shows on hover; the last row is where a new one is typed. Taking a
/// row away asks first.
struct RowList: View {
    let items: [String]
    let placeholder: String
    let icon: (String) -> URL?
    let removal: (String) -> String
    let normalise: (String) -> String?
    let save: ([String]) -> Void
    @State private var adding = ""
    @State private var hovered: String?

    var body: some View {
        ForEach(items, id: \.self) { item in
            HStack(spacing: 10) {
                SiteIcon(url: icon(item))
                Text(item).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button {
                    Task { if await Dialogs.ask(removal(item), yes: "Remove") { save(items.filter { $0 != item }) } }
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(hovered == item ? 1 : 0)
                .help("Remove")
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        }
        HStack(spacing: 10) {
            Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 16)
            // In a form, a field's title is a label beside it; the prompt is
            // the text inside it, which is what this row wants.
            TextField("", text: $adding, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.plain)
                .onSubmit(add)
        }
    }

    private func add() {
        let text = adding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = normalise(text), !items.contains(item) else { return }
        save(items + [item])
        adding = ""
    }
}

struct NewTabThumbnail: View {
    let version: Int

    var body: some View {
        Group {
            if let url = Settings.newTabImageInUse, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.1)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .id(version)
    }
}

extension NSColor {
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

// MARK: Help

struct HelpPage: View {
    private let rows = NSApp.mainMenu.map(Menus.shortcuts(in:)) ?? []

    /// Browser's own pages: typed into the address field, or by their keys.
    static let pages = [
        ("History", "about://history", "⌘H"),
        ("Downloads", "about://downloads", "⌘J"),
        ("Settings", "about://settings", "⌘,"),
        ("Help", "about://help", "⇧⌘/"),
    ]

    /// A shortcut's keys as keycaps; "A or B" is two.
    struct Keys: View {
        let text: String
        var body: some View {
            HStack(spacing: 4) {
                ForEach(text.components(separatedBy: " or "), id: \.self) { keys in
                    Text(keys)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    var body: some View {
        let sections = rows.reduce(into: [(String, [[String]])]()) { groups, row in
            if groups.last?.0 == row[0] { groups[groups.count - 1].1.append(row) } else { groups.append((row[0], [row])) }
        }
        Form {
            Section("Browser Pages") {
                ForEach(HelpPage.pages, id: \.0) { page in
                    LabeledContent(page.0) {
                        HStack(spacing: 10) {
                            Text(page.1)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Keys(text: page.2)
                        }
                    }
                }
            }
            ForEach(sections, id: \.0) { section in
                Section(section.0) {
                    ForEach(section.1, id: \.self) { row in
                        LabeledContent(row[1]) { Keys(text: row[2]) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .readableWidth()
    }
}

/// One of a setting's choices, as a segmented control.
struct Segmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    init(selection: Binding<Value>, _ options: [(Value, String)]) {
        _selection = selection
        self.options = options
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

/// A slider that stops on Settings' steps, with a notch at each.
struct Notched: NSViewRepresentable {
    @Binding var value: Int

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: 0, maxValue: Double(Settings.fillSteps),
                              target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.numberOfTickMarks = Settings.fillSteps + 1
        slider.allowsTickMarkValuesOnly = true
        slider.controlSize = .regular
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if slider.integerValue != value { slider.integerValue = value }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: Notched
        init(parent: Notched) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) { parent.value = slider.integerValue }
    }
}

// MARK: Downloads

/// about://downloads: every download until Clear, newest first.
struct DownloadsPage: View {
    @State private var items = Downloads.shared.items

    var body: some View {
        GeometryReader { geometry in
            let margin = Pages.margin(geometry.size.width)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Clear Downloads") {
                        Task {
                            if await Dialogs.ask("Clear the list of downloads?", detail: "The files stay where they are.", yes: "Clear") { Downloads.shared.clear() }
                        }
                    }
                        .controlSize(.large)
                        .buttonBorderShape(.capsule)
                        .disabled(items.allSatisfy { $0.state == .active })
                }
                .padding(.horizontal, margin + 16)
                .padding(.vertical, 16)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            DownloadRow(item: item)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .contentMargins(.horizontal, margin, for: .scrollContent)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Downloads.changed)) { _ in items = Downloads.shared.items }
    }
}

struct DownloadRow: View {
    let item: Downloads.Item
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: item.file.pathExtension) ?? .data))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(DownloadRow.status(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                if item.state == .active {
                    Button("Cancel") { Downloads.shared.cancel(item) }.buttonBorderShape(.capsule)
                } else {
                    if FileManager.default.fileExists(atPath: item.file.path) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.file]) }.buttonBorderShape(.capsule)
                    }
                    Button("Remove") { Downloads.shared.remove(item) }.buttonBorderShape(.capsule)
                }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if item.state == .finished { NSWorkspace.shared.open(item.file) } }
    }

    static func status(_ item: Downloads.Item) -> String {
        let size = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        let site = item.site.isEmpty ? "" : " · \(item.site)"
        switch item.state {
        case .active: return item.expected > 0 ? "\(size(item.received)) of \(size(item.expected))" : size(item.received)
        case .failed: return "Stopped\(site)"
        case .finished:
            let gone = FileManager.default.fileExists(atPath: item.file.path) ? "" : " · moved or deleted"
            return size(item.received) + site + gone
        }
    }
}
