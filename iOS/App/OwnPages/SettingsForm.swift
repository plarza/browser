import BrowserKit
import PhotosUI
import SwiftUI

/// Settings, as a sheet from the grid. The same form shows in a tab at
/// about://settings.
struct SettingsSheet: View {
    unowned let screen: ScreenActions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsForm { screen.show($0) }
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

/// The Mac's settings: the search engine, appearance, where new tabs open,
/// the new tab page, the cookie whitelist and the filter lists.
struct SettingsForm: View {
    /// Opens one of Browser's own pages; without it, the form has no links.
    var show: ((InternalPage) -> Void)?
    @Bindable private var preferences = Preferences.shared
    @State private var resetting = false

    var body: some View {
        Form {
            Section("Search Engine") {
                TextField("Search URL", text: $preferences.settings.searchTemplate, prompt: Text(verbatim: "https://example.com/search?q=%s"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(SearchEngine.all) { engine in
                            Button {
                                preferences.settings.searchTemplate = engine.template
                            } label: {
                                Label {
                                    Text(engine.name)
                                } icon: {
                                    EngineIcon(engine: engine)
                                }
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(preferences.settings.searchTemplate == engine.template ? .accentColor : .secondary)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Section("Appearance") {
                Picker("Appearance", selection: $preferences.settings.appearance) {
                    Text("Light").tag(Settings.Appearance.light)
                    Text("Dark").tag(Settings.Appearance.dark)
                    Text("System").tag(Settings.Appearance.system)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("New Tabs Open") {
                Picker("New Tabs Open", selection: $preferences.settings.newTabPosition) {
                    Text("After Current").tag(Settings.TabPosition.below)
                    Text("First").tag(Settings.TabPosition.top)
                    Text("Last").tag(Settings.TabPosition.bottom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            NewTabPageSettings()

            Section {
                EditableList(items: preferences.settings.whitelist, placeholder: "Add domain",
                             question: { ("Remove \($0)?", "Its cookies and site data will be deleted.") },
                             normalise: { Whitelist.normalise([$0]).first }) { preferences.settings.whitelist = $0 }
            } header: {
                Text("Cookie Whitelist")
            } footer: {
                Text("These sites and their subdomains keep one set of cookies, shared by every tab.")
            }

            Section {
                EditableList(items: preferences.settings.filterLists, placeholder: "Add filter list URL",
                             normalise: { URL(string: $0)?.scheme == "https" ? $0 : nil }) { preferences.settings.filterLists = $0 }
                Button("Update Now") { Blocker.shared.refresh(force: true) }
                    .disabled(Blocker.shared.isRefreshing)
                Button("Defaults") { resetting = true }
                    .disabled(preferences.settings.filterLists == Settings.defaultFilterLists)
            } header: {
                Text("Filter Lists")
            } footer: {
                FilterListStatus()
            }
            .alert("Reset filter lists?", isPresented: $resetting) {
                Button("Reset") { preferences.settings.filterLists = Settings.defaultFilterLists }
                Button("Cancel", role: .cancel) {}
            }

            if let show {
                Section {
                    Button("History", systemImage: "clock") { show(.history) }
                    Button("Downloads", systemImage: "arrow.down.circle") { show(.downloads) }
                }
            }
        }
    }
}

/// What a tab with nowhere to go shows: a picture from Photos or the
/// default, a colour, or blank.
private struct NewTabPageSettings: View {
    @Bindable private var preferences = Preferences.shared
    @State private var picked: PhotosPickerItem?

    var body: some View {
        Section("New Tab Page") {
            Picker("New Tab Page", selection: $preferences.settings.newTabPage) {
                Text("Image").tag(Settings.NewTabPage.image)
                Text("Color").tag(Settings.NewTabPage.color)
                Text("Blank").tag(Settings.NewTabPage.blank)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch preferences.settings.newTabPage {
            case .image:
                PhotosPicker(selection: $picked, matching: .images) {
                    LabeledContent("Choose Image…") { NewTabPageThumbnail() }
                }
                if FileManager.default.fileExists(atPath: Settings.newTabImage.path) {
                    Button("Use Default") {
                        try? FileManager.default.removeItem(at: Settings.newTabImage)
                        preferences.newTabImageChanged()
                    }
                }
            case .color:
                ColorPicker("Color", selection: Binding { Color(hex: preferences.settings.newTabColor) } set: { preferences.settings.newTabColor = $0.hex }, supportsOpacity: false)
            case .blank:
                EmptyView()
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                // Kept at most as large as a screen needs, beside the settings.
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                   let fitted = image.preparingThumbnail(of: image.size.fitting(2600)), let jpeg = fitted.jpegData(compressionQuality: 0.9) {
                    try? jpeg.write(to: Settings.newTabImage, options: [.atomic, .completeFileProtection])
                    preferences.newTabImageChanged()
                }
                picked = nil
            }
        }
    }

}

/// The picture blank tabs show now.
private struct NewTabPageThumbnail: View {
    var body: some View {
        let _ = Preferences.shared.newTabImageVersion
        if let image = Settings.newTabImageInUse.flatMap({ UIImage(contentsOfFile: $0.path) }) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 44, height: 30)
                .clipShape(.rect(cornerRadius: 6, style: .continuous))
        }
    }
}

private extension CGSize {
    /// The same shape, its longer side at most `longest`.
    func fitting(_ longest: CGFloat) -> CGSize {
        let scale = min(1, longest / max(width, height, 1))
        return CGSize(width: width * scale, height: height * scale)
    }
}

/// How the filter lists are doing: how many rules, when they were fetched,
/// and the last thing that went wrong.
private struct FilterListStatus: View {
    var body: some View {
        let blocker = Blocker.shared
        VStack(alignment: .leading, spacing: 2) {
            if blocker.isRefreshing {
                Text("Updating…")
            } else if let fetched = blocker.lastFetched {
                let when = fetched.formatted(.relative(presentation: .named))
                Text(blocker.ruleCount > 0 ? "\(blocker.ruleCount.formatted()) rules, fetched \(when)" : "Fetched \(when)")
            }
            if let trouble = blocker.trouble {
                Text(trouble).foregroundStyle(.red)
            }
        }
    }
}

/// A search engine's picture, from the app's `engines` folder.
private struct EngineIcon: View {
    let engine: SearchEngine

    var body: some View {
        if let image = EngineIcon.image(named: engine.icon) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
                .clipShape(.rect(cornerRadius: 3.5, style: .continuous))
        }
    }

    private static func image(named name: String) -> UIImage? {
        guard let file = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "engines") else { return nil }
        return file.pathExtension == "svg" ? vector(file) : UIImage(contentsOfFile: file.path)
    }

    /// UIKit reads an SVG only out of an asset catalog. A loose file goes
    /// through CoreSVG, the framework the catalogs' own SVGs are drawn with.
    private static func vector(_ file: URL) -> UIImage? {
        typealias Open = @convention(c) (CFData, CFDictionary?) -> Unmanaged<AnyObject>?
        typealias Make = @convention(c) (AnyObject, Selector, AnyObject) -> UIImage?
        let make = NSSelectorFromString("_imageWithCGSVGDocument:")
        guard let data = try? Data(contentsOf: file),
              let framework = dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG", RTLD_NOW),
              let open = dlsym(framework, "CGSVGDocumentCreateFromData"),
              let method = class_getClassMethod(UIImage.self, make),
              let document = unsafeBitCast(open, to: Open.self)(data as CFData, nil)?.takeRetainedValue()
        else { return nil }
        guard let drawing = unsafeBitCast(method_getImplementation(method), to: Make.self)(UIImage.self, make, document),
              drawing.size.width > 0, drawing.size.height > 0 else { return nil }
        // Drawn once into a bitmap, as large as the icon ever shows.
        let scale = 48 / max(drawing.size.width, drawing.size.height)
        let size = CGSize(width: drawing.size.width * scale, height: drawing.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in drawing.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
