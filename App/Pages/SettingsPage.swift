import AppKit
import BrowserKit
import SwiftUI

/// about://settings: the whole of what a person can set.
struct SettingsPage: View {
    @Bindable private var preferences = Preferences.shared

    var body: some View {
        Form {
            Section("Search Engine") {
                TextField("Search URL", text: $preferences.settings.searchTemplate, prompt: Text("https://example.com/search?q=%s"))
                    .labelsHidden()
                HStack {
                    ForEach(SearchEngine.all) { engine in
                        Button {
                            preferences.settings.searchTemplate = engine.template
                        } label: {
                            Label {
                                Text(engine.name)
                            } icon: {
                                if let image = engine.image {
                                    Image(nsImage: image).resizable().frame(width: 16, height: 16)
                                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                                }
                            }
                        }
                        .buttonBorderShape(.capsule)
                    }
                }
            }

            Section("Appearance") {
                Segmented(selection: $preferences.settings.appearance, [(.light, "Light"), (.dark, "Dark"), (.system, "System")])
            }

            Section("New Tabs Open") {
                Segmented(selection: $preferences.settings.newTabPosition,
                          [(.below, "Below Current Tab"), (.top, "At the Top"), (.bottom, "At the Bottom")])
            }

            Section("New Tab Page") { newTabPage }

            Section("Cookie Whitelist") {
                RowList(items: preferences.settings.whitelist, placeholder: "Add domain", icon: { URL(string: "https://\($0)") },
                        removal: { ("Remove \($0)?", "Its cookies and site data will be deleted.") },
                        normalise: { Whitelist.normalise([$0]).first }) { preferences.settings.whitelist = $0 }
            }

            Section("Filter Lists") {
                // Saving a changed list fetches and compiles them again.
                RowList(items: preferences.settings.filterLists, placeholder: "Add filter list URL", icon: { URL(string: $0) },
                        removal: { ("Remove \($0)?", "") },
                        normalise: { URL(string: $0)?.scheme == "https" ? $0 : nil }) { preferences.settings.filterLists = $0 }
                HStack {
                    Button("Update Now") { Blocker.shared.refresh(force: true) }.buttonBorderShape(.capsule)
                    Button("Defaults") {
                        Task {
                            guard await Dialogs.ask("Reset filter lists?", yes: "Reset") else { return }
                            // Already the defaults: fetch them again all the same.
                            if preferences.settings.filterLists == Settings.defaultFilterLists {
                                Blocker.shared.refresh(force: true)
                            } else {
                                preferences.settings.filterLists = Settings.defaultFilterLists
                            }
                        }
                    }
                    .buttonBorderShape(.capsule)
                    Spacer()
                    if Blocker.shared.ruleCount > 0 {
                        Text("\(Blocker.shared.ruleCount.formatted()) rules").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Safari Extensions") {
                ForEach(Extensions.shared.found) { item in
                    Toggle(item.name, isOn: Binding(
                        get: { Extensions.shared.enabled.contains(item.id) },
                        set: { on in Task { await Extensions.shared.setEnabled(item.id, on) } }
                    ))
                }
                if Extensions.shared.found.isEmpty {
                    Text("No Safari extensions installed.").foregroundStyle(.secondary)
                }
            }

            if let trouble = Blocker.shared.trouble ?? Extensions.shared.trouble {
                Text(trouble).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .readableWidth()
    }

    /// What a blank tab shows, and whether it fills the window behind a
    /// frosted sidebar.
    @ViewBuilder
    private var newTabPage: some View {
        Segmented(selection: $preferences.settings.newTabPage, [(.image, "Image"), (.color, "Color"), (.blank, "Blank")])
        switch preferences.settings.newTabPage {
        case .image:
            HStack(spacing: 12) {
                NewTabThumbnail(version: preferences.newTabImageVersion)
                Button("Choose Image…", action: chooseImage).buttonBorderShape(.capsule)
                if FileManager.default.fileExists(atPath: Settings.newTabImage.path) {
                    Button("Use Default") {
                        Task {
                            guard await Dialogs.ask("Use the default image?", yes: "Use Default") else { return }
                            try? FileManager.default.removeItem(at: Settings.newTabImage)
                            preferences.newTabImageChanged()
                        }
                    }
                    .buttonBorderShape(.capsule)
                }
            }
        case .color:
            ColorPicker("Color", selection: Binding(
                get: { Color(nsColor: NSColor(hex: preferences.settings.newTabColor)) },
                set: { preferences.settings.newTabColor = NSColor($0).hex }
            ), supportsOpacity: false)
        case .blank:
            EmptyView()
        }
        Toggle("Fill Behind Sidebar", isOn: $preferences.settings.fill)
        if preferences.settings.fill {
            if preferences.settings.newTabPage == .image {
                LabeledContent("Blur") { SmoothSlider(value: $preferences.settings.fillBlur) }
            }
            LabeledContent("Transparency") { SmoothSlider(value: $preferences.settings.fillTransparency) }
        }
    }

    /// A picture from Finder, copied beside the settings.
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        try? FileManager.default.removeItem(at: Settings.newTabImage)
        try? FileManager.default.copyItem(at: picked, to: Settings.newTabImage)
        preferences.settings.newTabPage = .image
        preferences.newTabImageChanged()
    }
}

extension SearchEngine {
    /// The engine's picture, which ships with Browser.
    var image: NSImage? {
        Bundle.main.url(forResource: icon, withExtension: nil, subdirectory: "Engines").flatMap(NSImage.init(contentsOf:))
    }
}
