import BrowserKit
import PhotosUI
import SwiftUI

/// The same settings as the Mac's, as a sheet from the tab grid.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsForm()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm) { dismiss() }
                    }
                }
        }
    }
}

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

    var image: UIImage? {
        Bundle.main.url(forResource: icon, withExtension: nil, subdirectory: "engines").flatMap { UIImage(contentsOfFile: $0.path) }
    }
}

struct SettingsForm: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var picture: PhotosPickerItem?

    var body: some View {
        Form {
            Section("Search Engine") {
                TextField("Search URL", text: $prefs.settings.searchTemplate, prompt: Text(verbatim: "https://example.com/search?q=%s"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(SearchEngine.all) { engine in
                            Button { prefs.settings.searchTemplate = engine.template } label: {
                                Label {
                                    Text(engine.name)
                                } icon: {
                                    if let image = engine.image {
                                        Image(uiImage: image).resizable().frame(width: 16, height: 16)
                                            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(prefs.settings.searchTemplate == engine.template ? .accentColor : .secondary)
                        }
                    }
                }
            }

            Section("Appearance") {
                Picker("Appearance", selection: $prefs.settings.appearance) {
                    Text("Light").tag(Settings.Appearance.light)
                    Text("Dark").tag(Settings.Appearance.dark)
                    Text("System").tag(Settings.Appearance.system)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("New Tabs Open") {
                Picker("New Tabs Open", selection: $prefs.settings.newTabPosition) {
                    Text("After Current").tag(Settings.TabPosition.below)
                    Text("First").tag(Settings.TabPosition.top)
                    Text("Last").tag(Settings.TabPosition.bottom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("New Tab Page") {
                Picker("New Tab Page", selection: $prefs.settings.newTabPage) {
                    Text("Image").tag(Settings.NewTabPage.image)
                    Text("Color").tag(Settings.NewTabPage.color)
                    Text("Blank").tag(Settings.NewTabPage.blank)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch prefs.settings.newTabPage {
                case .image:
                    PhotosPicker("Choose Image…", selection: $picture, matching: .images)
                    if FileManager.default.fileExists(atPath: Settings.newTabImage.path) {
                        Button("Use Default") {
                            try? FileManager.default.removeItem(at: Settings.newTabImage)
                            prefs.newTabImageChanged()
                        }
                    }
                case .color:
                    ColorPicker("Color", selection: Binding(
                        get: { Color(hex: prefs.settings.newTabColor) },
                        set: { prefs.settings.newTabColor = $0.hex }
                    ), supportsOpacity: false)
                case .blank:
                    EmptyView()
                }
            }
            .onChange(of: picture) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
                    try? FileManager.default.createDirectory(at: Settings.newTabImage.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? jpeg.write(to: Settings.newTabImage, options: [.atomic, .completeFileProtection])
                    prefs.newTabImageChanged()
                    picture = nil
                }
            }

            Section {
                RowList(items: prefs.settings.whitelist, placeholder: "Add domain",
                        removal: { ("Remove \($0)?", "Its cookies and site data will be deleted.") },
                        normalise: { Whitelist.normalise([$0]).first }) { prefs.settings.whitelist = $0 }
            } header: {
                Text("Cookie Whitelist")
            } footer: {
                Text("These sites and their subdomains keep one set of cookies, shared by every tab.")
            }

            Section("Filter Lists") {
                RowList(items: prefs.settings.filterLists, placeholder: "Add filter list URL",
                        removal: { ("Remove \($0)?", "") },
                        normalise: { URL(string: $0)?.scheme == "https" ? $0 : nil }) {
                    prefs.settings.filterLists = $0
                    Blocker.shared.refresh(force: true)
                }
                Button("Update Now") { Blocker.shared.refresh(force: true) }
                Button("Defaults") {
                    Task {
                        guard await Dialogs.confirm("Reset filter lists?", ok: "Reset", cancel: "Cancel") else { return }
                        prefs.settings.filterLists = Settings.defaultFilterLists
                        Blocker.shared.refresh(force: true)
                    }
                }
            }

            Section {
                NavigationLink("History") { HistoryList().navigationTitle("History") }
                NavigationLink("Downloads") { DownloadList().navigationTitle("Downloads") }
            }
        }
    }
}

/// A list you add to and remove from: the whitelist, the filter lists.
struct RowList: View {
    let items: [String]
    let placeholder: String
    let removal: (String) -> (String, String)
    let normalise: (String) -> String?
    let save: ([String]) -> Void
    @State private var adding = ""

    var body: some View {
        ForEach(items, id: \.self) { item in
            Text(item).lineLimit(1).truncationMode(.middle)
        }
        .onDelete { offsets in
            guard let i = offsets.first else { return }
            let (message, detail) = removal(items[i])
            Task {
                guard await Dialogs.confirm(detail.isEmpty ? message : "\(message)\n\(detail)", ok: "Remove", cancel: "Cancel", destructive: true) else { return }
                var next = items
                next.remove(atOffsets: offsets)
                save(next)
            }
        }
        TextField(placeholder, text: $adding)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .submitLabel(.done)
            .onSubmit {
                guard let item = normalise(adding.trimmingCharacters(in: .whitespaces)), !items.contains(item) else { return }
                save(items + [item])
                adding = ""
            }
    }
}

/// about://history: every word searched across addresses and titles.
struct HistoryList: View {
    @Environment(Browser.self) private var browser
    @State private var query = ""
    @State private var visits: [History.Visit] = []

    var body: some View {
        List {
            ForEach(visits, id: \.url) { visit in
                Button {
                    if let url = URL(string: visit.url) { browser.open(url) }
                    browser.showingSettings = false
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(visit.title.isEmpty ? visit.url : visit.title).lineLimit(1).foregroundStyle(.primary)
                        Text(AddressSheet.shortAddress(visit.url)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .onDelete { offsets in
                for i in offsets { History.shared.remove(visits[i].url) }
                visits.remove(atOffsets: offsets)
            }
        }
        .searchable(text: $query)
        .toolbar {
            Button("Clear") {
                Task {
                    guard await Dialogs.confirm("Clear all History?", ok: "Clear", cancel: "Cancel", destructive: true) else { return }
                    History.shared.clear()
                    visits = []
                }
            }
        }
        .task(id: query) { visits = History.shared.search(query) }
    }
}

/// about://downloads: what came down, into Browser's folder in Files.
struct DownloadList: View {
    @State private var items = Downloads.shared.items
    private let changed = NotificationCenter.default.publisher(for: Downloads.changed)

    var body: some View {
        List {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1)
                    Text("\(item.site) · \(item.state.rawValue.capitalized)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if items.isEmpty { Text("No downloads.").foregroundStyle(.secondary) }
        }
        .toolbar {
            if !items.isEmpty { Button("Clear") { Downloads.shared.clear() } }
        }
        .onReceive(changed) { _ in items = Downloads.shared.items }
    }
}

/// One of Browser's own pages, in a tab.
struct InternalPageView: View {
    let page: String

    var body: some View {
        NavigationStack {
            Group {
                switch page {
                case "history": HistoryList()
                case "downloads": DownloadList()
                case "settings": SettingsForm()
                default: List { Text("Swipe from the left edge to go back, from the right to go forward. Long press the address bar for Persist.") }
                }
            }
            .navigationTitle(page.capitalized)
        }
        .safeAreaPadding(.bottom, 70)
    }
}
